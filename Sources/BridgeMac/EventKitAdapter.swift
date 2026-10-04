import Foundation
import BridgeCore

public enum CalendarAccess: String { case notDetermined, fullAccess, denied, restricted, writeOnly }
public enum TargetCapability: String { case writableBusy, readOnly, busyUnsupported }
public enum EventKitAdapterError: Error, Equatable { case permissionRequired, duplicateCalendar, missingCalendar, incompleteRead, notWritable, busyUnsupported, writesDisabled, invalidOwnership, stalePlan, providerWriteFailed(completed: Int) }
public struct ProviderCalendar: Equatable {
    public let descriptor: CalendarDescriptor
    public var writable: Bool
    public var supportsBusy: Bool
    public init(descriptor: CalendarDescriptor, writable: Bool = true, supportsBusy: Bool = true) {
        self.descriptor = descriptor; self.writable = writable; self.supportsBusy = supportsBusy
    }
}
public struct ProviderEvent: Equatable {
    public let id: String
    public let event: SourceEvent
    public var safeToModify: Bool
    public init(id: String, event: SourceEvent, safeToModify: Bool = true) {
        self.id = id; self.event = event; self.safeToModify = safeToModify
    }
    public var block: ManagedBlock {
        ManagedBlock(id: id, sourceID: event.sourceID, calendarID: event.calendarID, title: event.title,
                     interval: event.interval, isAllDay: event.isAllDay, availability: event.availability, ownershipMarker: event.ownershipMarker)
    }
}
@MainActor public protocol CalendarProvider: AnyObject {
    var access: CalendarAccess { get }
    func requestAccess() async throws -> Bool
    func calendars() throws -> [ProviderCalendar]
    func events(calendar: ProviderCalendar, window: QueryWindow) throws -> [ProviderEvent]
    func event(id: String) throws -> ProviderEvent?
    func save(_ block: DesiredBlock, replacing: ProviderEvent?) throws
    func remove(_ event: ProviderEvent) throws
}
public struct SourceReadResult {
    public let descriptor: CalendarDescriptor
    public let events: [SourceEvent]
    public let blocks: [ManagedBlock]
    public var complete: Bool { if case .complete = descriptor.localRead { return true }; return false }
}
/// Serial EventKit boundary. The foreground app never calls authorizeReviewedPlan/apply.
@MainActor public final class EventKitAdapter {
    let provider: any CalendarProvider
    let installationID: UUID
    private var completeReads: [String: (CalendarPolicy, QueryWindow, SourceReadResult)] = [:]
    public private(set) var targetCapabilities: [String: TargetCapability] = [:]
    private var reviewedPlan: BusyPlan?
    private let receipts: OwnershipReceiptStore
    public init(provider: any CalendarProvider, installationID: UUID, receipts: OwnershipReceiptStore? = nil) {
        self.provider = provider; self.installationID = installationID
        self.receipts = receipts ?? OwnershipReceiptStore(installationID: installationID)
    }
    public var access: CalendarAccess { provider.access }
    public func requestAccess() async throws -> Bool { try await provider.requestAccess() }
    public func requiresRead(_ policy: CalendarPolicy) -> Bool {
        policy.exportToHA || policy.busySource || policy.busyTarget || receipts.hasProvenance(target: policy.identity)
    }
    public func inventory() throws -> [CalendarDescriptor] {
        try checkedInventory().map(\.descriptor)
    }
    private func checkedInventory() throws -> [ProviderCalendar] {
        guard access == .fullAccess else { throw EventKitAdapterError.permissionRequired }
        let calendars = try provider.calendars()
        guard access == .fullAccess else { throw EventKitAdapterError.permissionRequired }
        guard Set(calendars.map { $0.descriptor.identity }).count == calendars.count else { throw EventKitAdapterError.duplicateCalendar }
        targetCapabilities = Dictionary(uniqueKeysWithValues: calendars.map {
            ($0.descriptor.identity, !$0.writable ? .readOnly : (!$0.supportsBusy ? .busyUnsupported : .writableBusy))
        })
        return calendars
    }
    public func read(policy: CalendarPolicy, window: QueryWindow) throws -> SourceReadResult {
        completeReads.removeValue(forKey: policy.identity)
        reviewedPlan = nil
        func result(_ state: LocalCalendarRead, calendar: CalendarDescriptor? = nil, rows: [ProviderEvent] = []) -> SourceReadResult {
            let descriptor = CalendarDescriptor(sourceID: policy.sourceID, calendarID: policy.calendarID,
                name: calendar?.name ?? policy.label, owner: calendar?.owner ?? policy.owner,
                timeZoneID: calendar?.timeZoneID ?? TimeZone.current.identifier, localRead: state)
            return SourceReadResult(descriptor: descriptor, events: rows.map(\.event), blocks: rows.map(\.block))
        }
        do {
            guard window.start.timeIntervalSince1970.isFinite, window.end.timeIntervalSince1970.isFinite,
                  window.start < window.end else { throw EventKitAdapterError.incompleteRead }
            guard let calendar = try checkedInventory().first(where: { $0.descriptor.identity == policy.identity }) else {
                return result(.missing)
            }
            let rows = try checkedRows(calendar: calendar, window: window)
            let successful = result(.complete(window: window), calendar: calendar.descriptor, rows: rows)
            completeReads[policy.identity] = (policy, window, successful)
            return successful
        } catch { return result(.failed) }
    }
    private func checkedRows(calendar: ProviderCalendar, window: QueryWindow) throws -> [ProviderEvent] {
        guard access == .fullAccess else { throw EventKitAdapterError.permissionRequired }
        let rows = try provider.events(calendar: calendar, window: window)
        guard access == .fullAccess,
              try checkedInventory().contains(where: { $0.descriptor.identity == calendar.descriptor.identity }) else { throw EventKitAdapterError.incompleteRead }
        var distinct: [String: ProviderEvent] = [:]
        for row in rows {
            guard !row.id.isEmpty, !row.event.eventID.isEmpty, row.event.calendarIdentity == calendar.descriptor.identity,
                  row.event.interval.start.timeIntervalSince1970.isFinite, row.event.interval.end.timeIntervalSince1970.isFinite,
                  row.event.interval.start < row.event.interval.end else { throw EventKitAdapterError.incompleteRead }
            if let previous = distinct[row.id], previous != row { throw EventKitAdapterError.incompleteRead }
            distinct[row.id] = row
        }
        let unique = distinct.values.sorted { $0.id < $1.id }
        try receipts.observe(unique, target: calendar.descriptor.identity)
        return unique
    }
    /// Future callers must obtain explicit user review of this exact plan. Authorization is one-shot,
    /// in-memory only, and cleared by every read. No setting or launch path enables writes.
    public func authorizeReviewedPlan(_ plan: BusyPlan) throws {
        guard access == .fullAccess else { throw EventKitAdapterError.permissionRequired }
        guard !(provider is NativeEventKitProvider) || receipts.isPersistent else { throw EventKitAdapterError.writesDisabled }
        guard !plan.cleanupSuppressed || (plan.updates.isEmpty && plan.deletes.isEmpty) else { throw EventKitAdapterError.incompleteRead }
        reviewedPlan = plan
    }
    public func apply(_ plan: BusyPlan) throws {
        guard reviewedPlan == plan else { throw EventKitAdapterError.writesDisabled }
        reviewedPlan = nil
        var completed = 0
        // Provider edits to originals since the reviewed local read invalidate the plan.
        for (_, entry) in completeReads where entry.0.busySource || entry.0.busyTarget {
            let calendar = try currentCalendar(entry.0.identity)
            let current = try checkedRows(calendar: calendar, window: entry.1).map(\.event).filter { Ownership.decode($0.ownershipMarker) == nil }
            let previous = entry.2.events.filter { Ownership.decode($0.ownershipMarker) == nil }
            guard current == previous else { throw EventKitAdapterError.stalePlan }
        }
        // Validate the full mutation surface before the first write.
        for block in plan.creates + plan.updates.map(\.replacement) { _ = try target(block) }
        for block in plan.deletes { _ = try targetIdentity(block.calendarIdentity, interval: block.interval); try validateMarker(block.ownershipMarker, identity: block.calendarIdentity) }
        for block in plan.creates {
            let calendar = try target(block)
            let rows = try checkedRows(calendar: calendar, window: completeReads[calendar.descriptor.identity]!.1)
            let marker = Ownership.decode(block.ownershipMarker)!
            let read = completeReads[calendar.descriptor.identity]!
            let sameLink = rows.filter { Ownership.decode($0.event.ownershipMarker)?.linkID == marker.linkID && Ownership.decode($0.event.ownershipMarker)?.installationID == installationID }
            let protected = sameLink.filter { $0.event.interval.start < read.1.start || $0.event.interval.end > read.1.end }
            let expectedProtected = read.2.blocks.filter {
                let owned = Ownership.decode($0.ownershipMarker)
                return owned?.installationID == installationID && owned?.linkID == marker.linkID
                    && ($0.interval.start < read.1.start || $0.interval.end > read.1.end)
            }
            guard protected.count == expectedProtected.count else { throw EventKitAdapterError.stalePlan }
            for row in protected {
                // The planner preserves boundary rows and may create uncovered Busy time beside
                // them. Ignore only the exact owned boundary row from the reviewed complete read;
                // new/changed/cross-target rows invalidate this plan rather than authorize a write.
                guard row.safeToModify, Ownership.decode(row.event.ownershipMarker) == marker,
                      expectedProtected.contains(row.block) else { throw EventKitAdapterError.stalePlan }
            }
            let matches = sameLink.filter { $0.event.interval.start >= read.1.start && $0.event.interval.end <= read.1.end }
            if !matches.isEmpty {
                guard matches.count == 1, matches[0].safeToModify, Ownership.decode(matches[0].event.ownershipMarker) == marker,
                      matches[0].event.title == "Занято", matches[0].event.interval == block.interval,
                      matches[0].event.isAllDay == block.isAllDay, matches[0].event.availability == .busy else { throw EventKitAdapterError.stalePlan }
                continue
            }
            try receipts.beginCreate(block)
            do {
                try provider.save(block, replacing: nil)
                completed += 1
                _ = try checkedRows(calendar: calendar, window: completeReads[calendar.descriptor.identity]!.1)
            } catch {
                // Recover the row ID if the provider committed before reporting failure. If the
                // result remains uncertain, the durable pending record blocks subsequent reads.
                _ = try? checkedRows(calendar: calendar, window: completeReads[calendar.descriptor.identity]!.1)
                throw EventKitAdapterError.providerWriteFailed(completed: completed)
            }
        }
        for update in plan.updates {
            let calendar = try target(update.replacement)
            let rows = try checkedRows(calendar: calendar, window: completeReads[calendar.descriptor.identity]!.1)
            guard let existing = rows.first(where: { $0.id == update.existingID }), existing.safeToModify else { throw EventKitAdapterError.stalePlan }
            try validateMarker(existing.event.ownershipMarker, identity: calendar.descriptor.identity)
            guard Ownership.decode(existing.event.ownershipMarker) == Ownership.decode(update.replacement.ownershipMarker) else { throw EventKitAdapterError.invalidOwnership }
            guard let expected = completeReads[calendar.descriptor.identity]?.2.blocks.first(where: { $0.id == update.existingID }),
                  existing.block == expected || (existing.event.interval == update.replacement.interval && existing.event.ownershipMarker == update.replacement.ownershipMarker && existing.event.title == "Занято" && existing.event.isAllDay == update.replacement.isAllDay) else { throw EventKitAdapterError.stalePlan }
            if existing.event.title == "Занято", existing.event.interval == update.replacement.interval,
               existing.event.isAllDay == update.replacement.isAllDay, existing.event.availability == .busy { continue }
            do { try provider.save(update.replacement, replacing: existing); completed += 1 }
            catch { throw EventKitAdapterError.providerWriteFailed(completed: completed) }
        }
        // Deletes run last; a failed create/update never reaches this loop.
        for block in plan.deletes {
            let calendar = try targetIdentity(block.calendarIdentity, interval: block.interval)
            let rows = try checkedRows(calendar: calendar, window: completeReads[calendar.descriptor.identity]!.1)
            guard let existing = rows.first(where: { $0.id == block.id }) else {
                // A moved block may be outside the query window. Only a direct, authorized local
                // identifier lookup can establish absence; window omission is never deletion.
                guard try provider.event(id: block.id) == nil, access == .fullAccess else { throw EventKitAdapterError.stalePlan }
                _ = try currentCalendar(block.calendarIdentity)
                continue
            }
            try validateMarker(existing.event.ownershipMarker, identity: block.calendarIdentity)
            guard existing.safeToModify, existing.block == block else { throw EventKitAdapterError.stalePlan }
            do { try provider.remove(existing); completed += 1 }
            catch { throw EventKitAdapterError.providerWriteFailed(completed: completed) }
        }
    }
    private func currentCalendar(_ identity: String) throws -> ProviderCalendar {
        guard let calendar = try checkedInventory().first(where: { $0.descriptor.identity == identity }) else { throw EventKitAdapterError.missingCalendar }
        return calendar
    }
    private func targetIdentity(_ identity: String, interval: EventInterval) throws -> ProviderCalendar {
        guard let read = completeReads[identity], interval.start < interval.end,
              interval.start >= read.1.start, interval.end <= read.1.end else { throw EventKitAdapterError.incompleteRead }
        let calendar = try currentCalendar(identity)
        guard calendar.writable else { throw EventKitAdapterError.notWritable }
        guard calendar.supportsBusy else { throw EventKitAdapterError.busyUnsupported }
        return calendar
    }
    private func target(_ block: DesiredBlock) throws -> ProviderCalendar {
        let identity = CalendarPolicy.identity(sourceID: block.sourceID, calendarID: block.calendarID)
        guard completeReads[identity]?.0.busyTarget == true, block.title == "Занято" else { throw EventKitAdapterError.stalePlan }
        try validateMarker(block.ownershipMarker, identity: identity)
        return try targetIdentity(identity, interval: block.interval)
    }
    private func validateMarker(_ value: String?, identity: String) throws {
        guard let marker = Ownership.decode(value), marker.installationID == installationID,
              let expected = try? Ownership(installationID: installationID).encode(linkID: marker.linkID, targetIdentity: identity, sourceIdentities: [identity]),
              marker.targetID == Ownership.decode(expected)?.targetID else { throw EventKitAdapterError.invalidOwnership }
    }
}
