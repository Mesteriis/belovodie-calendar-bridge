import Foundation

/// Persist both provider IDs. Names are display data and never define identity.
public struct CalendarPolicy: Codable, Equatable, Sendable {
    public let sourceID: String
    public let calendarID: String
    public var owner: String
    public var label: String
    public var exportToHA: Bool
    public var busySource: Bool
    public var busyTarget: Bool

    public init(sourceID: String, calendarID: String, owner: String, label: String,
                exportToHA: Bool = false, busySource: Bool = false, busyTarget: Bool = false) {
        self.sourceID = sourceID
        self.calendarID = calendarID
        self.owner = owner
        self.label = label
        self.exportToHA = exportToHA
        self.busySource = busySource
        self.busyTarget = busyTarget
    }

    /// The exact key required by `completeSources`, collision-safe even for IDs containing separators.
    public var identity: String { Self.identity(sourceID: sourceID, calendarID: calendarID) }

    public static func identity(sourceID: String, calendarID: String) -> String {
        "\(sourceID.utf8.count):\(sourceID)\(calendarID.utf8.count):\(calendarID)"
    }
}

/// Half-open absolute interval. Provider adapters must resolve timezone/DST boundaries before planning.
public struct EventInterval: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

public struct QueryWindow: Codable, Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

public enum ParticipationStatus: String, Codable, Sendable {
    case accepted, tentative, organizer, declined, pending, unknown
}

public enum EventAvailability: String, Codable, Sendable {
    case busy, free, tentative, unavailable, unknown
}

public struct SourceEvent: Codable, Equatable, Sendable {
    public let sourceID: String
    public let calendarID: String
    public let eventID: String
    /// Stable original recurrence anchor, not the moved start date. Nil for nonrecurring events.
    public let occurrenceID: String?
    public let title: String
    public let interval: EventInterval
    public let isAllDay: Bool
    public let participation: ParticipationStatus
    public let availability: EventAvailability
    public let isCancelled: Bool
    public let ownershipMarker: String?
    /// Provider event timezone; snapshot export falls back to the calendar timezone.
    public let timeZoneID: String?

    public init(sourceID: String, calendarID: String, eventID: String, occurrenceID: String? = nil,
                title: String, interval: EventInterval, isAllDay: Bool = false,
                participation: ParticipationStatus = .unknown, availability: EventAvailability = .unknown,
                isCancelled: Bool = false, ownershipMarker: String? = nil, timeZoneID: String? = nil) {
        self.sourceID = sourceID
        self.calendarID = calendarID
        self.eventID = eventID
        self.occurrenceID = occurrenceID
        self.title = title
        self.interval = interval
        self.isAllDay = isAllDay
        self.participation = participation
        self.availability = availability
        self.isCancelled = isCancelled
        self.ownershipMarker = ownershipMarker
        self.timeZoneID = timeZoneID
    }

    public var calendarIdentity: String { CalendarPolicy.identity(sourceID: sourceID, calendarID: calendarID) }

    // Length-delimited fields distinguish ordinary events from recurring instances without using moved times.
    var instanceIdentity: String {
        let fields = [calendarIdentity, eventID, occurrenceID == nil ? "single" : "recurring", occurrenceID ?? ""]
        return fields.map { "\($0.utf8.count):\($0)" }.joined()
    }
}

/// Boundary input may include ordinary or foreign events; only a valid local marker authorizes mutation.
public struct ManagedBlock: Codable, Equatable, Sendable {
    public let id: String
    public let sourceID: String
    public let calendarID: String
    public let title: String
    public let interval: EventInterval
    public let isAllDay: Bool
    public let availability: EventAvailability
    public let ownershipMarker: String?

    public init(id: String, sourceID: String, calendarID: String, title: String,
                interval: EventInterval, isAllDay: Bool = false, availability: EventAvailability = .unknown, ownershipMarker: String?) {
        self.id = id
        self.sourceID = sourceID
        self.calendarID = calendarID
        self.title = title
        self.interval = interval
        self.isAllDay = isAllDay
        self.availability = availability
        self.ownershipMarker = ownershipMarker
    }

    private enum CodingKeys: String, CodingKey { case id, sourceID, calendarID, title, interval, isAllDay, availability, ownershipMarker }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        sourceID = try values.decode(String.self, forKey: .sourceID)
        calendarID = try values.decode(String.self, forKey: .calendarID)
        title = try values.decode(String.self, forKey: .title)
        interval = try values.decode(EventInterval.self, forKey: .interval)
        isAllDay = try values.decode(Bool.self, forKey: .isAllDay)
        availability = try values.decodeIfPresent(EventAvailability.self, forKey: .availability) ?? .unknown
        ownershipMarker = try values.decodeIfPresent(String.self, forKey: .ownershipMarker)
    }
    public var calendarIdentity: String { CalendarPolicy.identity(sourceID: sourceID, calendarID: calendarID) }
}

public struct DesiredBlock: Codable, Equatable, Sendable {
    public let sourceID: String
    public let calendarID: String
    public let title: String
    public let interval: EventInterval
    public let isAllDay: Bool
    public let ownershipMarker: String
}

public struct BlockUpdate: Codable, Equatable, Sendable {
    public let existingID: String
    public let replacement: DesiredBlock
}

public struct BusyPlan: Equatable, Sendable {
    public let creates: [DesiredBlock]
    public let updates: [BlockUpdate]
    public let deletes: [ManagedBlock]
    /// At least one required read is incomplete; adapters should surface this state.
    public let cleanupSuppressed: Bool
}

public enum BusyPlannerError: Error, Equatable {
    case invalidWindow
    case invalidEventInterval
    case duplicateCalendarPolicy
    case ambiguousEventIdentity
}
