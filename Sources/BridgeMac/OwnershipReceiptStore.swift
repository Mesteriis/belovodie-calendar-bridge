import Foundation
import BridgeCore

/// Private provenance only: no titles, account names, URLs, or attendee data.
/// A pending create survives commit-before-error and quarantines an uncertain target.
@MainActor public final class OwnershipReceiptStore {
    private struct Receipt: Codable, Equatable { let target: String; let rowID: String; let marker: String }
    private struct Pending: Codable, Equatable {
        let target: String
        let marker: String
        // Private intended block bounds distinguish a new create from protected same-link rows.
        // Legacy pending records decode without these fields and remain quarantined.
        let interval: EventInterval?
        let isAllDay: Bool?
    }
    private struct State: Codable { let version: Int; let installationID: UUID; var receipts: [Receipt]; var pending: [Pending] }
    var isPersistent: Bool { storage != nil }
    private var state: State
    private let storage: AtomicStore?
    init(installationID: UUID) {
        state = State(version: 1, installationID: installationID, receipts: [], pending: [])
        storage = nil
    }
    public init(directoryURL: URL, installationID: UUID) throws {
        let storage = AtomicStore(fileURL: directoryURL.appendingPathComponent("ownership-receipts.json"))
        self.storage = storage
        if let data = try storage.load() {
            let loaded = try JSONDecoder().decode(State.self, from: data)
            guard loaded.version == 1, loaded.installationID == installationID,
                  loaded.receipts.allSatisfy({ Self.valid($0.marker, target: $0.target, installationID: installationID) }),
                  loaded.pending.allSatisfy({ Self.valid($0.marker, target: $0.target, installationID: installationID) }) else { throw EventKitAdapterError.invalidOwnership }
            state = loaded
        } else { state = State(version: 1, installationID: installationID, receipts: [], pending: []) }
    }
    private static func valid(_ marker: String?, target: String, installationID: UUID) -> Bool {
        guard let decoded = Ownership.decode(marker), decoded.installationID == installationID,
              let expected = try? Ownership(installationID: installationID).encode(linkID: decoded.linkID, targetIdentity: target, sourceIdentities: [target]) else { return false }
        return decoded.targetID == Ownership.decode(expected)?.targetID
    }
    func hasProvenance(target: String) -> Bool {
        state.receipts.contains { $0.target == target } || state.pending.contains { $0.target == target }
    }
    func observe(_ rows: [ProviderEvent], target: String) throws {
        // A known row is uncertain if its provider removes/changes ownership. Keep it out of
        // source/export reads and never authorize repair by title or time alone.
        for row in rows {
            // Provider-local row IDs are store-wide evidence. A known row moved into a different
            // calendar remains uncertain even if its notes were stripped or replaced on that move.
            for receipt in state.receipts where receipt.rowID == row.id {
                guard receipt.target == target,
                      Ownership.decode(row.event.ownershipMarker) == Ownership.decode(receipt.marker) else {
                    throw EventKitAdapterError.invalidOwnership
                }
            }
        }
        var updated = state
        for row in rows where Self.valid(row.event.ownershipMarker, target: target, installationID: state.installationID) {
            let receipt = Receipt(target: target, rowID: row.id, marker: row.event.ownershipMarker!)
            updated.receipts.removeAll { $0.target == target && $0.rowID == row.id }
            updated.receipts.append(receipt)
        }
        updated.pending.removeAll { pending in
            guard pending.target == target, let interval = pending.interval, let isAllDay = pending.isAllDay else { return false }
            return rows.contains {
                $0.safeToModify && Ownership.decode($0.event.ownershipMarker) == Ownership.decode(pending.marker)
                    && $0.event.interval == interval && $0.event.isAllDay == isAllDay
                    && $0.event.availability == .busy && $0.event.title == "Занято"
            }
        }
        try persist(updated)
        guard !state.pending.contains(where: { $0.target == target }) else { throw EventKitAdapterError.incompleteRead }
    }
    func beginCreate(_ block: DesiredBlock) throws {
        let target = CalendarPolicy.identity(sourceID: block.sourceID, calendarID: block.calendarID)
        guard Self.valid(block.ownershipMarker, target: target, installationID: state.installationID) else { throw EventKitAdapterError.invalidOwnership }
        var updated = state
        let pending = Pending(target: target, marker: block.ownershipMarker, interval: block.interval, isAllDay: block.isAllDay)
        if !updated.pending.contains(pending) { updated.pending.append(pending) }
        try persist(updated)
    }
    private func persist(_ updated: State) throws {
        if let storage { try storage.save(JSONEncoder().encode(updated)) }
        state = updated
    }
}
