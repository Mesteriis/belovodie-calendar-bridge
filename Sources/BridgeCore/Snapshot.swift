import CryptoKit
import Foundation

public enum LocalCalendarRead: Equatable, Sendable {
    case complete(window: QueryWindow)
    case failed
    case missing
    case confirmedRemoved
}

public struct CalendarDescriptor: Equatable, Sendable {
    public let sourceID: String
    public let calendarID: String
    public let name: String
    public let owner: String
    public let timeZoneID: String
    public let localRead: LocalCalendarRead

    public init(sourceID: String, calendarID: String, name: String, owner: String,
                timeZoneID: String, localRead: LocalCalendarRead) {
        self.sourceID = sourceID
        self.calendarID = calendarID
        self.name = name
        self.owner = owner
        self.timeZoneID = timeZoneID
        self.localRead = localRead
    }
    public var identity: String { CalendarPolicy.identity(sourceID: sourceID, calendarID: calendarID) }
}

public enum LocalCalendarHealth: String, Codable, Sendable { case complete, failed, missing }
public struct SnapshotEvent: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let start: String
    public let end: String
    public let isAllDay: Bool
    public let timeZoneID: String
    public let startDate: String?
    public let endDate: String?
}
public struct SnapshotCalendar: Codable, Equatable, Sendable {
    public let id: String
    public let owner: String
    public let label: String
    public let localHealth: LocalCalendarHealth
    public let remoteHealth: String
    public let observedAt: String
    public let lastSuccessfulObservedAt: String?
    public let events: [SnapshotEvent]?
}
public enum SnapshotRemovalReason: String, Codable, Sendable { case exportDisabled, confirmedRemoved }
public struct SnapshotRemoval: Codable, Equatable, Sendable {
    public let id: String
    public let reason: SnapshotRemovalReason
}
public struct SnapshotWindow: Codable, Equatable, Sendable {
    public let start: String
    public let end: String
}
public struct CalendarSnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let observedAt: String
    public let window: SnapshotWindow
    public let calendars: [SnapshotCalendar]
    public let removals: [SnapshotRemoval]
}
public enum SnapshotError: Error, Equatable {
    case invalidWindow, invalidObservation, duplicatePolicy, duplicateCalendar, invalidTimeZone
    case invalidEventInterval, invalidAllDayBoundary, ambiguousEventIdentity
}
public struct SnapshotBuilder: Sendable {
    public let installationID: UUID
    public init(installationID: UUID) { self.installationID = installationID }
    public func build(events: [SourceEvent], policies: [CalendarPolicy], inventory: [CalendarDescriptor],
                      window: QueryWindow, observedAt: Date) throws -> CalendarSnapshot {
        guard valid(window.start), valid(window.end), window.start < window.end else { throw SnapshotError.invalidWindow }
        guard valid(observedAt) else { throw SnapshotError.invalidObservation }
        guard Set(policies.map(\.identity)).count == policies.count else { throw SnapshotError.duplicatePolicy }
        guard Set(inventory.map(\.identity)).count == inventory.count else { throw SnapshotError.duplicateCalendar }
        let descriptors = Dictionary(uniqueKeysWithValues: inventory.map { ($0.identity, $0) })
        let observation = instant(observedAt, zone: TimeZone(secondsFromGMT: 0)!)
        var calendars: [SnapshotCalendar] = []
        var removals: [SnapshotRemoval] = []
        let selected = Set(policies.filter(\.exportToHA).map(\.identity))
        var originals: [String: SourceEvent] = [:]
        for event in events where selected.contains(event.calendarIdentity) && Ownership.decode(event.ownershipMarker) == nil {
            if let previous = originals[event.instanceIdentity], previous != event { throw SnapshotError.ambiguousEventIdentity }
            originals[event.instanceIdentity] = event
        }
        for policy in policies.sorted(by: { $0.identity < $1.identity }) {
            let id = opaqueID(domain: "calendar", identity: policy.identity)
            guard policy.exportToHA else {
                removals.append(SnapshotRemoval(id: id, reason: .exportDisabled))
                continue
            }
            let descriptor = descriptors[policy.identity]
            if descriptor?.localRead == .confirmedRemoved {
                removals.append(SnapshotRemoval(id: id, reason: .confirmedRemoved))
                continue
            }
            let health: LocalCalendarHealth
            switch descriptor?.localRead {
            case .complete(let readWindow) where readWindow == window: health = .complete
            case .missing, nil: health = .missing
            default: health = .failed
            }
            var exported: [SnapshotEvent]? = nil
            if health == .complete, let descriptor {
                guard let calendarZone = TimeZone(identifier: descriptor.timeZoneID) else { throw SnapshotError.invalidTimeZone }
                exported = try originals.values.filter { $0.calendarIdentity == policy.identity && !$0.isCancelled }
                    .sorted { $0.instanceIdentity < $1.instanceIdentity }.compactMap { event in
                        guard valid(event.interval.start), valid(event.interval.end), event.interval.start < event.interval.end else {
                            throw SnapshotError.invalidEventInterval
                        }
                        guard event.interval.start < window.end, event.interval.end > window.start else { return nil }
                        let zone: TimeZone
                        if let identifier = event.timeZoneID {
                            guard let eventZone = TimeZone(identifier: identifier) else { throw SnapshotError.invalidTimeZone }
                            zone = eventZone
                        } else { zone = calendarZone }
                        var startDate: String? = nil
                        var endDate: String? = nil
                        if event.isAllDay {
                            var calendar = Calendar(identifier: .gregorian)
                            calendar.timeZone = zone
                            guard calendar.startOfDay(for: event.interval.start) == event.interval.start,
                                  calendar.startOfDay(for: event.interval.end) == event.interval.end else {
                                throw SnapshotError.invalidAllDayBoundary
                            }
                            startDate = day(event.interval.start, zone: zone)
                            endDate = day(event.interval.end, zone: zone)
                        }
                        return SnapshotEvent(id: opaqueID(domain: "instance", identity: event.instanceIdentity), title: event.title,
                            start: instant(event.interval.start, zone: zone), end: instant(event.interval.end, zone: zone),
                            isAllDay: event.isAllDay, timeZoneID: zone.identifier, startDate: startDate, endDate: endDate)
                    }
            }
            calendars.append(SnapshotCalendar(id: id, owner: policy.owner, label: policy.label, localHealth: health,
                remoteHealth: "unknown", observedAt: observation,
                lastSuccessfulObservedAt: health == .complete ? observation : nil, events: exported))
        }
        return CalendarSnapshot(version: 1, observedAt: observation,
            window: SnapshotWindow(start: instant(window.start, zone: TimeZone(secondsFromGMT: 0)!),
                                   end: instant(window.end, zone: TimeZone(secondsFromGMT: 0)!)),
            calendars: calendars, removals: removals)
    }

    private func valid(_ date: Date) -> Bool { date.timeIntervalSince1970.isFinite }
    private func opaqueID(domain: String, identity: String) -> String {
        let input = [installationID.uuidString.lowercased(), domain, identity].map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func instant(_ date: Date, zone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = zone
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    private func day(_ date: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
