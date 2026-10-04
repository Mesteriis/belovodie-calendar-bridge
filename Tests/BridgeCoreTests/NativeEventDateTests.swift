import Foundation
import XCTest
@testable import BridgeCore
@testable import BridgeMac

/// Exercises the exact date conversion consumed by NativeEventKitProvider without an EKEventStore.
final class NativeEventDateTests: XCTestCase {
    private func instant(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }
    private func snapshot(_ dates: NativeEventReadDates, allDay: Bool, window: QueryWindow) throws -> SnapshotEvent {
        let policy = CalendarPolicy(sourceID: "account", calendarID: "calendar", owner: "Owner", label: "Calendar", exportToHA: true)
        let event = SourceEvent(sourceID: "account", calendarID: "calendar", eventID: "event", occurrenceID: dates.occurrenceID, title: "Fixture", interval: dates.interval, isAllDay: allDay, timeZoneID: dates.timeZoneID)
        let descriptor = CalendarDescriptor(sourceID: "account", calendarID: "calendar", name: "Calendar", owner: "Owner", timeZoneID: "Europe/Madrid", localRead: .complete(window: window))
        let snapshot = try SnapshotBuilder(installationID: UUID()).build(events: [event], policies: [policy], inventory: [descriptor], window: window, observedAt: window.start)
        return try XCTUnwrap(snapshot.calendars.first?.events?.first)
    }
    func testAllDayNativeUTCUsesSystemMadridAcrossDSTWithoutMovingInstants() throws {
        let system = try XCTUnwrap(TimeZone(identifier: "Europe/Madrid"))
        let native = try XCTUnwrap(TimeZone(identifier: "Etc/UTC"))
        for (startText, endText, day, endDay, hours) in [
            ("2026-03-29T00:00:00+01:00", "2026-03-30T00:00:00+02:00", "2026-03-29", "2026-03-30", 23.0),
            ("2026-10-25T00:00:00+02:00", "2026-10-26T00:00:00+01:00", "2026-10-25", "2026-10-26", 25.0)
        ] {
            let start = try instant(startText), end = try instant(endText)
            let originalAnchor = try instant("2026-03-22T00:00:00+01:00")
            let dates = NativeEventReadDates(start: start, end: end, isAllDay: true, nativeTimeZone: native, occurrenceDate: originalAnchor, systemTimeZone: system)
            XCTAssertEqual(dates.interval.start, start); XCTAssertEqual(dates.interval.end, end)
            XCTAssertEqual(dates.occurrenceID, "2026-03-22")
            let exported = try snapshot(dates, allDay: true, window: QueryWindow(start: start, end: end))
            XCTAssertEqual(exported.timeZoneID, "Europe/Madrid")
            XCTAssertEqual(exported.startDate, day); XCTAssertEqual(exported.endDate, endDay)
            XCTAssertEqual(try instant(exported.start.replacingOccurrences(of: ".000", with: "")), start)
            XCTAssertEqual(try instant(exported.end.replacingOccurrences(of: ".000", with: "")), end)
            XCTAssertEqual(end.timeIntervalSince(start), hours * 3600)
        }
    }
    func testTimedNativeUTCIsPreservedWithNoAllDayDatesOrAnchorReinterpretation() throws {
        let system = try XCTUnwrap(TimeZone(identifier: "Europe/Madrid"))
        let native = try XCTUnwrap(TimeZone(identifier: "Etc/UTC"))
        let start = try instant("2026-03-29T12:00:00Z"), end = try instant("2026-03-29T13:00:00Z")
        let anchor = try instant("2026-03-22T12:00:00Z")
        let dates = NativeEventReadDates(start: start, end: end, isAllDay: false, nativeTimeZone: native, occurrenceDate: anchor, systemTimeZone: system)
        XCTAssertEqual(dates.interval.start, start); XCTAssertEqual(dates.interval.end, end)
        XCTAssertEqual(dates.timeZoneID, "Etc/UTC")
        XCTAssertEqual(dates.occurrenceID, String(anchor.timeIntervalSinceReferenceDate))
        let exported = try snapshot(dates, allDay: false, window: QueryWindow(start: start, end: end))
        XCTAssertEqual(exported.timeZoneID, "Etc/UTC"); XCTAssertNil(exported.startDate); XCTAssertNil(exported.endDate)
        XCTAssertEqual(exported.start, "2026-03-29T12:00:00.000Z"); XCTAssertEqual(exported.end, "2026-03-29T13:00:00.000Z")
        let floating = NativeEventReadDates(start: start, end: end, isAllDay: false, nativeTimeZone: nil, occurrenceDate: nil, systemTimeZone: system)
        XCTAssertEqual(floating.timeZoneID, "Europe/Madrid"); XCTAssertNil(floating.occurrenceID)
    }
}
