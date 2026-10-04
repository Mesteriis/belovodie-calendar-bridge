import Foundation
import EventKit
import BridgeCore

/// Pure conversion of EventKit's already-resolved dates; never moves or rounds provider instants.
struct NativeEventReadDates {
    let interval: EventInterval
    let timeZoneID: String
    let occurrenceID: String?
    init(start: Date, end: Date, isAllDay: Bool, nativeTimeZone: TimeZone?, occurrenceDate: Date?, systemTimeZone: TimeZone) {
        interval = EventInterval(start: start, end: end)
        // EKEvent.h: floating/all-day startDate and occurrenceDate use defaultTimeZone,
        // even if the event carries another explicit zone. Timed events retain that zone.
        timeZoneID = (isAllDay ? systemTimeZone : (nativeTimeZone ?? systemTimeZone)).identifier
        occurrenceID = occurrenceDate.map { anchor in
            if isAllDay {
                let formatter = DateFormatter()
                formatter.calendar = Calendar(identifier: .gregorian)
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = systemTimeZone
                formatter.dateFormat = "yyyy-MM-dd"
                return formatter.string(from: anchor)
            }
            return String(anchor.timeIntervalSinceReferenceDate)
        }
    }
}

/// Owns the only EKEventStore. It is created by the bundled app, never by a shell helper.
@MainActor public final class NativeEventKitProvider: CalendarProvider {
    private let store = EKEventStore()
    public init() {}
    public var access: CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .fullAccess
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .writeOnly: .writeOnly
        default: .denied
        }
    }
    public func requestAccess() async throws -> Bool {
        do { return try await store.requestFullAccessToEvents() }
        catch { throw EventKitAdapterError.permissionRequired }
    }
    public func calendars() throws -> [ProviderCalendar] {
        guard access == .fullAccess else { throw EventKitAdapterError.permissionRequired }
        return store.calendars(for: .event).map { calendar in
            ProviderCalendar(descriptor: CalendarDescriptor(sourceID: calendar.source.sourceIdentifier,
                calendarID: calendar.calendarIdentifier, name: calendar.title, owner: calendar.source.title,
                // EKCalendar exposes no timezone. Floating/all-day events use the system default zone.
                timeZoneID: TimeZone.current.identifier, localRead: .failed),
                writable: calendar.allowsContentModifications,
                supportsBusy: calendar.supportedEventAvailabilities.contains(.busy))
        }
    }
    public func events(calendar: ProviderCalendar, window: QueryWindow) throws -> [ProviderEvent] {
        let native = try resolveCalendar(calendar.descriptor.sourceID, calendar.descriptor.calendarID)
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: [native])
        let events = try store.events(matching: predicate).map(convert)
        guard access == .fullAccess else { throw EventKitAdapterError.permissionRequired }
        return events
    }
    private func resolveCalendar(_ sourceID: String, _ calendarID: String) throws -> EKCalendar {
        guard access == .fullAccess else { throw EventKitAdapterError.permissionRequired }
        let matching = store.calendars(for: .event).filter { $0.calendarIdentifier == calendarID && $0.source.sourceIdentifier == sourceID }
        guard matching.count == 1, let calendar = matching.first else { throw EventKitAdapterError.missingCalendar }
        return calendar
    }
    private func convert(_ event: EKEvent) throws -> ProviderEvent {
        guard let calendar = event.calendar, let start = event.startDate, let end = event.endDate,
              let identifier = event.eventIdentifier, !identifier.isEmpty else { throw EventKitAdapterError.incompleteRead }
        let recurring = event.hasRecurrenceRules || event.isDetached
        guard !recurring || event.occurrenceDate != nil else { throw EventKitAdapterError.incompleteRead }
        let dates = NativeEventReadDates(start: start, end: end, isAllDay: event.isAllDay,
            nativeTimeZone: event.timeZone, occurrenceDate: recurring ? event.occurrenceDate : nil,
            systemTimeZone: event.isAllDay ? NSTimeZone.default : TimeZone.current)
        let occurrence = dates.occurrenceID
        let currentParticipant = event.attendees?.first { $0.isCurrentUser }
        let participation: ParticipationStatus
        if event.organizer?.isCurrentUser == true { participation = .organizer }
        else {
            switch currentParticipant?.participantStatus {
            case .accepted: participation = .accepted
            case .declined: participation = .declined
            case .tentative: participation = .tentative
            case .pending: participation = .pending
            default: participation = .unknown
            }
        }
        let availability: EventAvailability
        switch event.availability {
        case .busy: availability = .busy
        case .free: availability = .free
        case .tentative: availability = .tentative
        case .unavailable: availability = .unavailable
        default: availability = .unknown
        }
        // EventKit may share a local identifier across instances. Distinguish rows using the
        // original occurrence anchor, and never attempt to mutate a recurring source instance.
        let rowID = occurrence.map { "recurring:\(identifier.utf8.count):\(identifier):\($0)" } ?? identifier
        return ProviderEvent(id: rowID, event: SourceEvent(sourceID: calendar.source.sourceIdentifier,
            calendarID: calendar.calendarIdentifier,
            eventID: event.calendarItemExternalIdentifier ?? event.calendarItemIdentifier,
            occurrenceID: occurrence, title: event.title ?? "", interval: dates.interval,
            isAllDay: event.isAllDay, participation: participation, availability: availability,
            isCancelled: event.status == .canceled, ownershipMarker: event.notes,
            timeZoneID: dates.timeZoneID),
            safeToModify: !recurring && !(event.attendees?.isEmpty == false))
    }
    public func event(id: String) throws -> ProviderEvent? {
        guard access == .fullAccess else { throw EventKitAdapterError.permissionRequired }
        guard let event = store.event(withIdentifier: id) else { return nil }
        guard event.refresh() else { throw EventKitAdapterError.incompleteRead }
        let converted = try convert(event)
        guard access == .fullAccess else { throw EventKitAdapterError.permissionRequired }
        return converted
    }
    private func currentEvent(_ expected: ProviderEvent) throws -> EKEvent {
        guard let event = store.event(withIdentifier: expected.id), event.refresh(),
              try convert(event) == expected, expected.safeToModify else { throw EventKitAdapterError.stalePlan }
        return event
    }
    public func save(_ block: DesiredBlock, replacing: ProviderEvent?) throws {
        let calendar = try resolveCalendar(block.sourceID, block.calendarID)
        guard calendar.allowsContentModifications else { throw EventKitAdapterError.notWritable }
        guard calendar.supportedEventAvailabilities.contains(.busy) else { throw EventKitAdapterError.busyUnsupported }
        let event = try replacing.map(currentEvent) ?? EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = "Занято"
        event.startDate = block.interval.start
        event.endDate = block.interval.end
        event.isAllDay = block.isAllDay
        event.timeZone = TimeZone.current
        event.notes = block.ownershipMarker
        event.location = nil
        event.url = nil
        event.alarms = []
        event.recurrenceRules = nil
        event.availability = .busy
        try store.save(event, span: .thisEvent, commit: true)
    }
    public func remove(_ expected: ProviderEvent) throws {
        let calendar = try resolveCalendar(expected.event.sourceID, expected.event.calendarID)
        guard calendar.allowsContentModifications else { throw EventKitAdapterError.notWritable }
        let event = try currentEvent(expected)
        try store.remove(event, span: .thisEvent, commit: true)
    }
}
