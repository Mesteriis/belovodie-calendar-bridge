import Foundation
import XCTest
@testable import BridgeCore

final class SnapshotTests: XCTestCase {
    let installation = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let window = QueryWindow(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 2_000_000_000))
    let observed = Date(timeIntervalSince1970: 1_000)
    func policy(_ id: String = "private-calendar-a", enabled: Bool = true) -> CalendarPolicy {
        CalendarPolicy(sourceID: "private-source", calendarID: id, owner: "Owner", label: "Chosen label",
                       exportToHA: enabled, busySource: false, busyTarget: false)
    }
    func descriptor(_ id: String = "private-calendar-a", read: LocalCalendarRead? = nil,
                    zone: String = "Europe/Madrid") -> CalendarDescriptor {
        CalendarDescriptor(sourceID: "private-source", calendarID: id, name: "Provider name", owner: "Provider owner",
                           timeZoneID: zone, localRead: read ?? .complete(window: window))
    }
    func event(_ id: String, title: String = "Original", marker: String? = nil, calendarID: String = "private-calendar-a",
               start: Date = Date(timeIntervalSince1970: 100), end: Date = Date(timeIntervalSince1970: 200),
               allDay: Bool = false, zone: String? = nil, occurrence: String? = nil) -> SourceEvent {
        SourceEvent(sourceID: "private-source", calendarID: calendarID, eventID: id, occurrenceID: occurrence,
                    title: title, interval: EventInterval(start: start, end: end), isAllDay: allDay,
                    ownershipMarker: marker, timeZoneID: zone)
    }
    func build(_ events: [SourceEvent] = [], policies: [CalendarPolicy]? = nil,
               inventory: [CalendarDescriptor]? = nil) throws -> CalendarSnapshot {
        try SnapshotBuilder(installationID: installation).build(events: events, policies: policies ?? [policy()],
            inventory: inventory ?? [descriptor()], window: window, observedAt: observed)
    }
    func testFiltersBeforeEncodingKeepsNormalBusyAndChosenLabels() throws {
        let own = try Ownership(installationID: installation).encode(linkID: String(repeating: "a", count: 64), targetIdentity: policy().identity, sourceIdentities: [policy("other").identity])
        let foreign = try Ownership(installationID: UUID()).encode(linkID: String(repeating: "b", count: 64), targetIdentity: policy().identity, sourceIdentities: [policy("other").identity])
        let result = try build([event("normal", title: "Занято"), event("own", title: "Must not export own", marker: own),
                                event("foreign", title: "Must not export foreign", marker: foreign),
                                event("off", title: "Must not export disabled", calendarID: "off")],
                               policies: [policy(), policy("off", enabled: false)], inventory: [descriptor(), descriptor("off")])
        XCTAssertEqual(result.calendars.count, 1)
        XCTAssertEqual(result.calendars.first?.events?.map(\.title), ["Занято"])
        XCTAssertEqual(result.calendars.first?.owner, "Owner")
        XCTAssertEqual(result.calendars.first?.label, "Chosen label")
        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        for secret in ["private-source", "private-calendar-a", "belovodie-busy", "Must not export", "Provider name"] {
            XCTAssertFalse(json.contains(secret), secret)
        }
    }
    func testIncompleteReadsDoNotPublishAuthoritativeEmptyEvents() throws {
        for read in [LocalCalendarRead.failed, .missing, .complete(window: QueryWindow(start: window.start, end: observed))] {
            let result = try build([event("partial")], inventory: [descriptor(read: read)])
            XCTAssertNil(result.calendars.first?.events)
            XCTAssertNil(result.calendars.first?.lastSuccessfulObservedAt)
            XCTAssertNotEqual(result.calendars.first?.localHealth, .complete)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
            let calendars = try XCTUnwrap(object["calendars"] as? [[String: Any]])
            XCTAssertNil(calendars.first?["events"])
        }
        let missing = try build(inventory: [])
        XCTAssertEqual(missing.calendars.first?.localHealth, .missing)
        XCTAssertTrue(missing.removals.isEmpty)
        let empty = try build()
        XCTAssertEqual(empty.calendars.first?.events, [])
        XCTAssertEqual(empty.calendars.first?.localHealth, .complete)
        XCTAssertEqual(empty.calendars.first?.lastSuccessfulObservedAt, empty.observedAt)
        XCTAssertEqual(empty.calendars.first?.remoteHealth, "unknown")
    }
    func testOnlyExplicitDisableOrConfirmedRemovalProducesOpaqueRemoval() throws {
        let disabled = try build(policies: [policy(enabled: false)])
        XCTAssertTrue(disabled.calendars.isEmpty)
        XCTAssertEqual(disabled.removals.first?.reason, .exportDisabled)
        let removed = try build(inventory: [descriptor(read: .confirmedRemoved)])
        XCTAssertTrue(removed.calendars.isEmpty)
        XCTAssertEqual(removed.removals.first?.reason, .confirmedRemoved)
        XCTAssertEqual(disabled.removals.first?.id, removed.removals.first?.id)
        XCTAssertTrue(try build(policies: []).removals.isEmpty)
    }
    func testOpaqueIDsAreStableAcrossMovesAndRenameDistinctForInstances() throws {
        let first = try build([event("private-event", occurrence: "anchor-a"), event("private-event", occurrence: "anchor-b")])
        var renamed = policy(); renamed.label = "Renamed"
        let moved = try build([event("private-event", start: observed, end: observed.addingTimeInterval(500), occurrence: "anchor-a")], policies: [renamed])
        XCTAssertEqual(first.calendars.first?.id, moved.calendars.first?.id)
        XCTAssertEqual(first.calendars.first?.events?.first?.id, moved.calendars.first?.events?.first?.id)
        XCTAssertNotEqual(first.calendars.first?.events?.first?.id, first.calendars.first?.events?.last?.id)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(first), as: UTF8.self).contains("private-event"))
    }
    func testAllDayDatesRespectDSTAndEventTimezone() throws {
        let format = ISO8601DateFormatter()
        let start = format.date(from: "2026-03-29T00:00:00+01:00")!
        let end = format.date(from: "2026-03-30T00:00:00+02:00")!
        let result = try build([event("day", start: start, end: end, allDay: true, zone: "Europe/Madrid")])
        let day = try XCTUnwrap(result.calendars.first?.events?.first)
        XCTAssertEqual(day.startDate, "2026-03-29"); XCTAssertEqual(day.endDate, "2026-03-30")
        XCTAssertEqual(day.timeZoneID, "Europe/Madrid")
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let encodedStart = try XCTUnwrap(format.date(from: day.start))
        let encodedEnd = try XCTUnwrap(format.date(from: day.end))
        XCTAssertEqual(encodedEnd.timeIntervalSince(encodedStart), 23 * 3600)
        XCTAssertThrowsError(try build([event("bad", allDay: true)]))
        XCTAssertThrowsError(try build(inventory: [descriptor(zone: "not-a-zone")]))
    }
    func testTimedFreeOriginalRetainsTimezoneAndWindowOverlap() throws {
        let before = event("before", start: Date(timeIntervalSince1970: -20), end: Date(timeIntervalSince1970: -10))
        let overlap = event("overlap", start: Date(timeIntervalSince1970: -10), end: Date(timeIntervalSince1970: 10), zone: "America/New_York")
        let free = SourceEvent(sourceID: "private-source", calendarID: "private-calendar-a", eventID: "free", title: "Free original",
            interval: EventInterval(start: Date(timeIntervalSince1970: 300), end: Date(timeIntervalSince1970: 400)), availability: .free)
        let result = try build([before, overlap, free])
        XCTAssertEqual(result.calendars.first?.events?.count, 2)
        let timed = try XCTUnwrap(result.calendars.first?.events?.first { $0.title == "Original" })
        XCTAssertFalse(timed.isAllDay); XCTAssertNil(timed.startDate); XCTAssertNil(timed.endDate)
        XCTAssertEqual(timed.timeZoneID, "America/New_York")
        XCTAssertTrue(timed.start.hasSuffix("-05:00"))
        XCTAssertEqual(result.window.start, "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(result.observedAt, "1970-01-01T00:16:40.000Z")
    }
    func testInvalidWindowObservationAndOriginalIntervalFailVisibly() throws {
        let builder = SnapshotBuilder(installationID: installation)
        XCTAssertThrowsError(try builder.build(events: [], policies: [policy()], inventory: [descriptor()],
            window: QueryWindow(start: observed, end: observed), observedAt: observed))
        XCTAssertThrowsError(try builder.build(events: [], policies: [policy()], inventory: [descriptor()],
            window: window, observedAt: Date(timeIntervalSince1970: .nan)))
        XCTAssertThrowsError(try build([event("bad", start: observed, end: observed)]))
    }
    func testDuplicateConflictsFailInsteadOfReturningPartialSnapshot() throws {
        XCTAssertThrowsError(try build([event("same"), event("same", title: "Conflict")]))
        XCTAssertEqual(try build([event("same"), event("same")]).calendars.first?.events?.count, 1)
        XCTAssertThrowsError(try build(policies: [policy(), policy()]))
        XCTAssertThrowsError(try build(inventory: [descriptor(), descriptor()]))
    }
}
