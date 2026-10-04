import Foundation
import XCTest
@testable import BridgeCore
@testable import BridgeMac

@MainActor final class EventKitContractTests: XCTestCase {
    let installation = UUID()
    let window = QueryWindow(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1000))
    func policy(_ id: String, source: Bool = false, target: Bool = false) -> CalendarPolicy {
        CalendarPolicy(sourceID: "account", calendarID: id, owner: "Owner", label: id, busySource: source, busyTarget: target)
    }
    func providerCalendar(_ id: String) -> ProviderCalendar {
        ProviderCalendar(descriptor: CalendarDescriptor(sourceID: "account", calendarID: id, name: id, owner: "Owner", timeZoneID: "Europe/Madrid", localRead: .failed))
    }
    func fixture() throws -> (FakeCalendarProvider, EventKitAdapter, BusyPlan) {
        let fake = FakeCalendarProvider()
        fake.inventory = [providerCalendar("source"), providerCalendar("target")]
        let original = SourceEvent(sourceID: "account", calendarID: "source", eventID: "original", title: "Private original", interval: EventInterval(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200)))
        fake.rows = [ProviderEvent(id: "original", event: original)]
        let adapter = EventKitAdapter(provider: fake, installationID: installation)
        let policies = [policy("source", source: true), policy("target", target: true)]
        let reads = try policies.map { try adapter.read(policy: $0, window: window) }
        let plan = try BusyPlanner(installationID: installation).plan(events: reads.flatMap(\.events), policies: policies, existing: reads.flatMap(\.blocks), window: window, completeSources: Set(reads.filter(\.complete).map { $0.descriptor.identity }))
        return (fake, adapter, plan)
    }
    func testDeniedInventoryAndReadNeverReturnSuccessfulEmpty() throws {
        let fake = FakeCalendarProvider(); fake.access = .denied
        let adapter = EventKitAdapter(provider: fake, installationID: installation)
        XCTAssertThrowsError(try adapter.inventory())
        let result = try adapter.read(policy: policy("target"), window: window)
        XCTAssertFalse(result.complete); XCTAssertEqual(result.descriptor.localRead, .failed)
    }
    func testMissingAndDuplicateCalendarFailClosed() throws {
        let fake = FakeCalendarProvider()
        let adapter = EventKitAdapter(provider: fake, installationID: installation)
        XCTAssertEqual(try adapter.read(policy: policy("missing"), window: window).descriptor.localRead, .missing)
        fake.inventory = [providerCalendar("target"), providerCalendar("target")]
        XCTAssertThrowsError(try adapter.inventory())
        XCTAssertFalse(try adapter.read(policy: policy("target"), window: window).complete)
    }
    func testPartialQueryAndPermissionRevocationProduceFailedRead() throws {
        let fake = FakeCalendarProvider(); fake.inventory = [providerCalendar("target")]; fake.failRead = true
        let adapter = EventKitAdapter(provider: fake, installationID: installation)
        XCTAssertFalse(try adapter.read(policy: policy("target"), window: window).complete)
        fake.failRead = false; fake.revokeDuringRead = true
        XCTAssertFalse(try adapter.read(policy: policy("target"), window: window).complete)
    }
    func testNewCalendarsNeverEnableFlags() throws {
        let fake = FakeCalendarProvider(); fake.inventory = [providerCalendar("target")]
        var settings = BridgeSettings(); settings.discover(try EventKitAdapter(provider: fake, installationID: installation).inventory())
        XCTAssertEqual(settings.policies.count, 1); XCTAssertFalse(settings.policies.contains { $0.exportToHA || $0.busySource || $0.busyTarget })
    }
    func testWritesRequireExplicitPlanAuthorizationAndAreIdempotent() throws {
        let (fake, adapter, plan) = try fixture()
        XCTAssertEqual(plan.creates.count, 1)
        XCTAssertThrowsError(try adapter.apply(plan)); XCTAssertEqual(fake.writes, 0)
        try adapter.authorizeReviewedPlan(plan); try adapter.apply(plan)
        try adapter.authorizeReviewedPlan(plan); try adapter.apply(plan)
        XCTAssertEqual(fake.writes, 1); XCTAssertEqual(fake.rows.last?.event.title, "Занято")
    }
    func testReadOnlyAndUnsupportedBusyTargetsRejectWrites() throws {
        for busySupported in [true, false] {
            let (fake, adapter, plan) = try fixture()
            fake.inventory[1].writable = !busySupported; fake.inventory[1].supportsBusy = busySupported
            try adapter.authorizeReviewedPlan(plan)
            XCTAssertThrowsError(try adapter.apply(plan)); XCTAssertEqual(fake.writes, 0)
        }
    }
    func testStrippedOrMovedOwnershipNeverPermitsUpdateOrDelete() throws {
        let (fake, adapter, plan) = try fixture()
        try adapter.authorizeReviewedPlan(plan); try adapter.apply(plan)
        let existing = try XCTUnwrap(fake.rows.last)
        let deletePlan = BusyPlan(creates: [], updates: [], deletes: [existing.block], cleanupSuppressed: false)
        fake.rows[fake.rows.count - 1] = ProviderEvent(id: existing.id, event: SourceEvent(sourceID: existing.event.sourceID, calendarID: existing.event.calendarID, eventID: existing.event.eventID, title: "Занято", interval: existing.event.interval, ownershipMarker: nil))
        try adapter.authorizeReviewedPlan(deletePlan)
        XCTAssertThrowsError(try adapter.apply(deletePlan)); XCTAssertEqual(fake.writes, 1)
    }
    func testInterruptedCreateCanBeReplannedAndRetriedWithoutDuplicates() throws {
        let (fake, adapter, plan) = try fixture()
        fake.failWriteAfterPersist = true
        try adapter.authorizeReviewedPlan(plan); XCTAssertThrowsError(try adapter.apply(plan))
        fake.failWriteAfterPersist = false
        try adapter.authorizeReviewedPlan(plan); try adapter.apply(plan)
        XCTAssertEqual(fake.writes, 1)
    }
    func testDurableKnownRowWithStrippedMarkerFailsReadAndNeverBecomesOriginal() throws {
        let (fake, adapter, plan) = try fixture()
        try adapter.authorizeReviewedPlan(plan); try adapter.apply(plan)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsStore = SettingsStore(directoryURL: directory)
        let settings = try settingsStore.load()
        // Use a matching durable installation, as the bundled app does before any provider operation.
        let owned = try XCTUnwrap(fake.rows.last)
        let marker = try Ownership(installationID: settings.installationID).encode(linkID: String(repeating: "a", count: 64), targetIdentity: policy("target").identity, sourceIdentities: [policy("source").identity])
        fake.rows[fake.rows.count - 1] = ProviderEvent(id: owned.id, event: SourceEvent(sourceID: "account", calendarID: "target", eventID: owned.event.eventID, title: "Занято", interval: owned.event.interval, ownershipMarker: marker))
        let first = EventKitAdapter(provider: fake, installationID: settings.installationID, receipts: try OwnershipReceiptStore(directoryURL: directory, installationID: settings.installationID))
        XCTAssertTrue(try first.read(policy: policy("target", source: true), window: window).complete)
        fake.rows[fake.rows.count - 1] = ProviderEvent(id: owned.id, event: SourceEvent(sourceID: "account", calendarID: "target", eventID: owned.event.eventID, title: "Занято", interval: owned.event.interval))
        let restarted = EventKitAdapter(provider: fake, installationID: settings.installationID, receipts: try OwnershipReceiptStore(directoryURL: directory, installationID: settings.installationID))
        let read = try restarted.read(policy: policy("target", source: true), window: window)
        XCTAssertEqual(read.descriptor.localRead, .failed); XCTAssertTrue(read.events.isEmpty); XCTAssertTrue(read.blocks.isEmpty)
        let snapshot = try SnapshotBuilder(installationID: settings.installationID).build(events: read.events, policies: [CalendarPolicy(sourceID: "account", calendarID: "target", owner: "Owner", label: "Target", exportToHA: true)], inventory: [read.descriptor], window: window, observedAt: Date())
        XCTAssertNil(snapshot.calendars.first?.events)
        XCTAssertEqual(fake.writes, 1)
    }
    func testOrdinaryBusyTitleRemainsAnOriginalAndUnselectedCalendarIsNotRead() throws {
        let fake = FakeCalendarProvider(); fake.inventory = [providerCalendar("target")]
        fake.rows = [ProviderEvent(id: "ordinary", event: SourceEvent(sourceID: "account", calendarID: "target", eventID: "ordinary", title: "Занято", interval: EventInterval(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200))))]
        let adapter = EventKitAdapter(provider: fake, installationID: installation)
        XCTAssertFalse(adapter.requiresRead(policy("target")))
        let read = try adapter.read(policy: policy("target", source: true), window: window)
        XCTAssertTrue(read.complete); XCTAssertEqual(read.events.count, 1); XCTAssertNil(read.events[0].ownershipMarker)
    }
    func testCommitBeforeErrorUpdateRetriesWithSameProvenance() throws {
        let (fake, adapter, createPlan) = try fixture()
        try adapter.authorizeReviewedPlan(createPlan); try adapter.apply(createPlan)
        let original = try XCTUnwrap(fake.rows.first { $0.event.calendarID == "source" })
        fake.rows[0] = ProviderEvent(id: original.id, event: SourceEvent(sourceID: "account", calendarID: "source", eventID: original.event.eventID, title: original.event.title, interval: EventInterval(start: Date(timeIntervalSince1970: 300), end: Date(timeIntervalSince1970: 400))))
        let policies = [policy("source", source: true), policy("target", target: true)]
        let reads = try policies.map { try adapter.read(policy: $0, window: window) }
        let updatePlan = try BusyPlanner(installationID: installation).plan(events: reads.flatMap(\.events), policies: policies, existing: reads.flatMap(\.blocks), window: window, completeSources: Set(policies.map(\.identity)))
        XCTAssertEqual(updatePlan.updates.count, 1)
        fake.failWriteAfterPersist = true
        try adapter.authorizeReviewedPlan(updatePlan); XCTAssertThrowsError(try adapter.apply(updatePlan))
        fake.failWriteAfterPersist = false
        try adapter.authorizeReviewedPlan(updatePlan); try adapter.apply(updatePlan)
        XCTAssertEqual(fake.rows.filter { Ownership.decode($0.event.ownershipMarker) != nil }.count, 1)
        XCTAssertEqual(fake.rows.last?.event.interval.start, Date(timeIntervalSince1970: 300))
        XCTAssertEqual(fake.writes, 2)
    }
    func testDeleteWindowOmissionDoesNotMeanDeleted() throws {
        let (fake, adapter, plan) = try fixture()
        try adapter.authorizeReviewedPlan(plan); try adapter.apply(plan)
        let owned = try XCTUnwrap(fake.rows.last)
        let deletePlan = BusyPlan(creates: [], updates: [], deletes: [owned.block], cleanupSuppressed: false)
        fake.rows[fake.rows.count - 1] = ProviderEvent(id: owned.id, event: SourceEvent(sourceID: "account", calendarID: "target", eventID: owned.event.eventID, title: "Занято", interval: EventInterval(start: Date(timeIntervalSince1970: 1100), end: Date(timeIntervalSince1970: 1200)), ownershipMarker: owned.event.ownershipMarker))
        try adapter.authorizeReviewedPlan(deletePlan); XCTAssertThrowsError(try adapter.apply(deletePlan))
        XCTAssertEqual(fake.writes, 1)
    }

    func testDraftFlagsRequireMatchingPreviewBeforeBecomingActive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("model-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeCalendarProvider(); fake.inventory = [providerCalendar("target")]
        let model = BridgeModel(directoryURL: directory, provider: fake)
        model.refreshInventory()
        model.settings?.policies[0].busySource = true
        model.applyReviewedSettings()
        XCTAssertFalse(try XCTUnwrap(model.activeSettings?.policies.first).busySource)
        model.dryRun(); XCTAssertTrue(model.canApplySettings)
        model.settings?.policies[0].busyTarget = true
        XCTAssertFalse(model.canApplySettings)
        model.dryRun(); model.applyReviewedSettings()
        XCTAssertTrue(try XCTUnwrap(model.activeSettings?.policies.first).busyTarget)
        XCTAssertEqual(fake.writes, 0)
    }
    func testDeniedPreviewDoesNotApplyInitialEnablement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("model-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = FakeCalendarProvider(); fake.inventory = [providerCalendar("target")]
        let model = BridgeModel(directoryURL: directory, provider: fake)
        model.refreshInventory(); model.settings?.policies[0].busySource = true
        fake.access = .denied
        model.dryRun()
        XCTAssertFalse(model.canApplySettings)
        XCTAssertFalse(try XCTUnwrap(model.activeSettings?.policies.first).busySource)
        XCTAssertEqual(fake.writes, 0)
    }

}
@MainActor final class FakeCalendarProvider: CalendarProvider {
    var access: CalendarAccess = .fullAccess
    var inventory: [ProviderCalendar] = []
    var rows: [ProviderEvent] = []
    var failRead = false
    var revokeDuringRead = false
    var failWriteAfterPersist = false
    var writes = 0
    func requestAccess() async throws -> Bool { access == .fullAccess }
    func calendars() throws -> [ProviderCalendar] { inventory }
    func events(calendar: ProviderCalendar, window: QueryWindow) throws -> [ProviderEvent] {
        if failRead { throw EventKitAdapterError.incompleteRead }
        if revokeDuringRead { access = .denied }
        return rows.filter { $0.event.calendarIdentity == calendar.descriptor.identity && $0.event.interval.start < window.end && $0.event.interval.end > window.start }
    }
    func event(id: String) throws -> ProviderEvent? { rows.first { $0.id == id } }
    func save(_ block: DesiredBlock, replacing: ProviderEvent?) throws {
        writes += 1
        let row = ProviderEvent(id: replacing?.id ?? "created-\(writes)", event: SourceEvent(sourceID: block.sourceID, calendarID: block.calendarID, eventID: replacing?.event.eventID ?? "created-\(writes)", title: block.title, interval: block.interval, isAllDay: block.isAllDay, availability: .busy, ownershipMarker: block.ownershipMarker))
        if let replacing { rows.removeAll { $0.id == replacing.id } }; rows.append(row)
        if failWriteAfterPersist { throw EventKitAdapterError.incompleteRead }
    }
    func remove(_ event: ProviderEvent) throws { writes += 1; rows.removeAll { $0.id == event.id } }
}
