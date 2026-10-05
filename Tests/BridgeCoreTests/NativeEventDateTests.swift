import Foundation
import XCTest
import EventKit
@testable import BridgeCore
@testable import BridgeMac

/// Exercises native date reads and unsaved write construction without provider access.
@MainActor final class NativeEventDateTests: XCTestCase {
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
    func testNativeWriteKeepsAllDayAcrossCreateUpdateAndDST() throws {
        let previousDefault = NSTimeZone.default
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Madrid"))
        NSTimeZone.default = zone
        defer { NSTimeZone.default = previousDefault }
        let store = EKEventStore() // Transient construction only: no permission, calendars, queries or saves.
        for (startText, endText) in [
            ("2026-11-29T00:00:00+01:00", "2026-11-30T00:00:00+01:00"),
            ("2026-03-29T00:00:00+01:00", "2026-03-30T00:00:00+02:00"),
            ("2026-10-25T00:00:00+02:00", "2026-10-26T00:00:00+01:00"),
            ("2026-03-28T00:00:00+01:00", "2026-03-30T00:00:00+02:00")
        ] {
            let start = try instant(startText), end = try instant(endText)
            let event = EKEvent(eventStore: store)
            for _ in 0..<2 { // The same configurator must also work when updating an all-day row.
                NativeEventWriteDates.configure(event, interval: EventInterval(start: start, end: end), isAllDay: true, timedTimeZone: zone)
                XCTAssertTrue(event.isAllDay)
                XCTAssertNil(event.timeZone)
                XCTAssertEqual(event.startDate, start)
                XCTAssertEqual(event.endDate, end.addingTimeInterval(-1))
                let canonical = NativeEventReadDates(start: event.startDate, end: event.endDate, isAllDay: event.isAllDay, nativeTimeZone: event.timeZone, occurrenceDate: nil, systemTimeZone: zone)
                XCTAssertEqual(canonical.interval, EventInterval(start: start, end: end))
            }
            let timedStart = start.addingTimeInterval(3600), timedEnd = start.addingTimeInterval(7200)
            NativeEventWriteDates.configure(event, interval: EventInterval(start: timedStart, end: timedEnd), isAllDay: false, timedTimeZone: zone)
            XCTAssertFalse(event.isAllDay)
            XCTAssertEqual(event.startDate, timedStart); XCTAssertEqual(event.endDate, timedEnd)
            XCTAssertEqual(event.timeZone, zone)
        }
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
    func testExactInclusiveAllDayEndsBecomeExclusiveForSnapshotAndBusyPlan() throws {
        let system = try XCTUnwrap(TimeZone(identifier: "Europe/Madrid"))
        for (startText, inclusiveText, exclusiveText, startDay, endDay, hours) in [
            ("2026-03-29T00:00:00+01:00", "2026-03-29T23:59:59+02:00", "2026-03-30T00:00:00+02:00", "2026-03-29", "2026-03-30", 23.0),
            ("2026-10-25T00:00:00+02:00", "2026-10-25T23:59:59+01:00", "2026-10-26T00:00:00+01:00", "2026-10-25", "2026-10-26", 25.0),
            ("2026-03-28T00:00:00+01:00", "2026-03-29T23:59:59+02:00", "2026-03-30T00:00:00+02:00", "2026-03-28", "2026-03-30", 47.0)
        ] {
            let start = try instant(startText), inclusive = try instant(inclusiveText), exclusive = try instant(exclusiveText)
            let dates = NativeEventReadDates(start: start, end: inclusive, isAllDay: true, nativeTimeZone: nil, occurrenceDate: nil, systemTimeZone: system)
            XCTAssertEqual(dates.interval.start, start); XCTAssertEqual(dates.interval.end, exclusive)
            XCTAssertEqual(dates.interval.end.timeIntervalSince(dates.interval.start), hours * 3600)
            let window = QueryWindow(start: start, end: exclusive)
            let exported = try snapshot(dates, allDay: true, window: window)
            XCTAssertEqual(exported.startDate, startDay); XCTAssertEqual(exported.endDate, endDay)
            let source = CalendarPolicy(sourceID: "account", calendarID: "calendar", owner: "Owner", label: "Calendar", busySource: true)
            let target = CalendarPolicy(sourceID: "account", calendarID: "target", owner: "Owner", label: "Target", busyTarget: true)
            let event = SourceEvent(sourceID: "account", calendarID: "calendar", eventID: "original", title: "Fixture", interval: dates.interval, isAllDay: true)
            let plan = try BusyPlanner(installationID: UUID()).plan(events: [event], policies: [source, target], existing: [], window: window, completeSources: [source.identity, target.identity])
            XCTAssertEqual(plan.creates.count, 1); XCTAssertEqual(plan.creates.first?.interval, EventInterval(start: start, end: exclusive))
            XCTAssertEqual(plan.creates.first?.isAllDay, true)
        }
    }
    func testTimedRowCannotResolveAllDayPendingIntentAcrossFreshTransactions() throws {
        let installation = UUID()
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Madrid"))
        let start = try instant("2026-11-29T00:00:00+01:00"), end = try instant("2026-11-30T00:00:00+01:00")
        let source = CalendarPolicy(sourceID: "account", calendarID: "source", owner: "Owner", label: "Source", busySource: true)
        let target = CalendarPolicy(sourceID: "account", calendarID: "target", owner: "Owner", label: "Target")
        let activeTarget = CalendarPolicy(sourceID: "account", calendarID: "target", owner: "Owner", label: "Target", busyTarget: true)
        let window = QueryWindow(start: start, end: end)
        let original = SourceEvent(sourceID: "account", calendarID: "source", eventID: "original", title: "Fixture", interval: EventInterval(start: start, end: end), isAllDay: true)
        let plan = try BusyPlanner(installationID: installation).plan(events: [original], policies: [source, activeTarget], existing: [], window: window, completeSources: [source.identity, activeTarget.identity])
        let desired = try XCTUnwrap(plan.creates.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("all-day-pending-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try OwnershipReceiptStore(directoryURL: directory, installationID: installation).beginCreate(desired)
        let fake = FakeCalendarProvider()
        fake.inventory = [ProviderCalendar(descriptor: CalendarDescriptor(sourceID: target.sourceID, calendarID: target.calendarID, name: "Target", owner: "Owner", timeZoneID: zone.identifier, localRead: .failed))]
        fake.rows = [ProviderEvent(id: "pending-row", event: SourceEvent(sourceID: target.sourceID, calendarID: target.calendarID, eventID: "pending-row", title: "Занято", interval: EventInterval(start: start, end: end.addingTimeInterval(-1)), isAllDay: false, availability: .busy, ownershipMarker: desired.ownershipMarker))]
        for _ in 0..<2 {
            let adapter = EventKitAdapter(provider: fake, installationID: installation, receipts: try OwnershipReceiptStore(directoryURL: directory, installationID: installation))
            adapter.beginReadTransaction()
            XCTAssertTrue(adapter.requiresRead(target)) // Even with every target flag disabled.
            XCTAssertFalse(try adapter.read(policy: target, window: window).complete)
            XCTAssertEqual(fake.writes, 0)
        }
        // Only an exact all-day canonical observation resolves the unchanged pending intent.
        let dates = NativeEventReadDates(start: start, end: end.addingTimeInterval(-1), isAllDay: true, nativeTimeZone: nil, occurrenceDate: nil, systemTimeZone: zone)
        fake.rows = [ProviderEvent(id: "pending-row", event: SourceEvent(sourceID: target.sourceID, calendarID: target.calendarID, eventID: "pending-row", title: "Занято", interval: dates.interval, isAllDay: true, availability: .busy, ownershipMarker: desired.ownershipMarker))]
        let adapter = EventKitAdapter(provider: fake, installationID: installation, receipts: try OwnershipReceiptStore(directoryURL: directory, installationID: installation))
        adapter.beginReadTransaction()
        XCTAssertTrue(try adapter.read(policy: target, window: window).complete)
        XCTAssertEqual(fake.writes, 0)
    }
    func testNearMidnightSubsecondAndNonMidnightStartAreNeverRounded() throws {
        let system = try XCTUnwrap(TimeZone(identifier: "Europe/Madrid"))
        let midnight = try instant("2026-03-29T00:00:00+01:00")
        let exclusive = try instant("2026-03-30T00:00:00+02:00")
        for (start, end) in [(midnight, exclusive.addingTimeInterval(-2)), (midnight, exclusive.addingTimeInterval(-60)), (midnight, exclusive.addingTimeInterval(-0.5)), (midnight, exclusive.addingTimeInterval(-1.5)), (midnight.addingTimeInterval(1), exclusive.addingTimeInterval(-1))] {
            let dates = NativeEventReadDates(start: start, end: end, isAllDay: true, nativeTimeZone: nil, occurrenceDate: nil, systemTimeZone: system)
            XCTAssertEqual(dates.interval.start, start); XCTAssertEqual(dates.interval.end, end)
            XCTAssertThrowsError(try snapshot(dates, allDay: true, window: QueryWindow(start: midnight, end: exclusive))) { error in
                XCTAssertEqual(error as? SnapshotError, .invalidAllDayBoundary)
            }
        }
        let timed = NativeEventReadDates(start: midnight, end: exclusive.addingTimeInterval(-1), isAllDay: false, nativeTimeZone: system, occurrenceDate: nil, systemTimeZone: system)
        XCTAssertEqual(timed.interval.end, exclusive.addingTimeInterval(-1))
        XCTAssertEqual(try snapshot(timed, allDay: false, window: QueryWindow(start: midnight, end: exclusive)).end, "2026-03-29T23:59:59.000+02:00")
    }
    func testManagedInclusiveEndResolvesPendingReceiptAndReplayWithoutDrift() throws {
        let system = try XCTUnwrap(TimeZone(identifier: "Europe/Madrid"))
        let start = try instant("2026-03-29T00:00:00+01:00"), exclusive = try instant("2026-03-30T00:00:00+02:00")
        let source = CalendarPolicy(sourceID: "account", calendarID: "source", owner: "Owner", label: "Source", busySource: true)
        let target = CalendarPolicy(sourceID: "account", calendarID: "target", owner: "Owner", label: "Target", busyTarget: true)
        let installation = UUID(), window = QueryWindow(start: start, end: exclusive)
        let original = SourceEvent(sourceID: "account", calendarID: "source", eventID: "original", title: "Fixture", interval: EventInterval(start: start, end: exclusive), isAllDay: true)
        let initial = try BusyPlanner(installationID: installation).plan(events: [original], policies: [source, target], existing: [], window: window, completeSources: [source.identity, target.identity])
        let desired = try XCTUnwrap(initial.creates.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inclusive-receipt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try OwnershipReceiptStore(directoryURL: directory, installationID: installation).beginCreate(desired)
        let observed = NativeEventReadDates(start: start, end: exclusive.addingTimeInterval(-1), isAllDay: true, nativeTimeZone: nil, occurrenceDate: nil, systemTimeZone: system)
        let provider = FakeCalendarProvider()
        provider.inventory = [source, target].map { ProviderCalendar(descriptor: CalendarDescriptor(sourceID: $0.sourceID, calendarID: $0.calendarID, name: $0.label, owner: $0.owner, timeZoneID: "Europe/Madrid", localRead: .failed)) }
        provider.rows = [ProviderEvent(id: "original", event: original), ProviderEvent(id: "managed", event: SourceEvent(sourceID: "account", calendarID: "target", eventID: "managed", title: "Занято", interval: observed.interval, isAllDay: true, availability: .busy, ownershipMarker: desired.ownershipMarker, timeZoneID: observed.timeZoneID))]
        let adapter = EventKitAdapter(provider: provider, installationID: installation, receipts: try OwnershipReceiptStore(directoryURL: directory, installationID: installation))
        let reads = try [source, target].map { try adapter.read(policy: $0, window: window) }
        XCTAssertTrue(reads.allSatisfy(\.complete))
        let repaired = try BusyPlanner(installationID: installation).plan(events: reads.flatMap(\.events), policies: [source, target], existing: reads.flatMap(\.blocks), window: window, completeSources: Set(reads.filter(\.complete).map { $0.descriptor.identity }))
        XCTAssertTrue(repaired.creates.isEmpty); XCTAssertTrue(repaired.updates.isEmpty); XCTAssertTrue(repaired.deletes.isEmpty)
        try adapter.authorizeReviewedPlan(initial); try adapter.apply(initial)
        XCTAssertEqual(provider.writes, 0); XCTAssertEqual(provider.rows.count, 2)
    }

}
