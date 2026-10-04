import Foundation
import XCTest
@testable import BridgeCore
@testable import BridgeMac

@MainActor final class CoordinatorTests: XCTestCase {
    private func fixture() throws -> (SyncCoordinator, FakeCalendarProvider, TestSyncClock, TestTransport, URL, BridgeSettings) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("coordinator-\(UUID())")
        let store = SettingsStore(directoryURL: directory)
        var settings = try store.load()
        settings.policies = [CalendarPolicy(sourceID: "account", calendarID: "source", owner: "Owner", label: "Source", exportToHA: true, busySource: true), CalendarPolicy(sourceID: "account", calendarID: "target", owner: "Owner", label: "Target", busyTarget: true)]
        try store.save(settings)
        let provider = FakeCalendarProvider()
        provider.inventory = ["source", "target"].map { ProviderCalendar(descriptor: CalendarDescriptor(sourceID: "account", calendarID: $0, name: $0, owner: "Owner", timeZoneID: "UTC", localRead: .failed)) }
        provider.rows = [ProviderEvent(id: "original", event: SourceEvent(sourceID: "account", calendarID: "source", eventID: "original", title: "Private $(event)", interval: EventInterval(start: Date(timeIntervalSince1970: 101), end: Date(timeIntervalSince1970: 201))))]
        let clock = TestSyncClock(); let transport = TestTransport()
        let coordinator = SyncCoordinator(adapter: EventKitAdapter(provider: provider, installationID: settings.installationID, receipts: try OwnershipReceiptStore(directoryURL: directory, installationID: settings.installationID)), settings: settings, directoryURL: directory, transport: transport, clock: clock)
        return (coordinator, provider, clock, transport, directory, settings)
    }
    private func settle() async { for _ in 0..<20 { await Task.yield() } }
    func testFiveSecondDebounceExportsWithoutWrites() async throws {
        let (sync, provider, clock, transport, dir, _) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        sync.requestSync(reason: .eventChanged); clock.advance(4); await settle()
        XCTAssertTrue(transport.snapshots.isEmpty)
        sync.requestSync(reason: .eventChanged); clock.advance(4); await settle()
        XCTAssertTrue(transport.snapshots.isEmpty)
        clock.advance(1); await settle()
        XCTAssertEqual(transport.snapshots.count, 1); XCTAssertEqual(provider.writes, 0)
        XCTAssertEqual(transport.snapshots.first?.calendars.first?.events?.first?.title, "Private $(event)")
    }
    func testSuspendedTransportSerializesAndCoalescesNotifications() async throws {
        let (sync, _, clock, transport, dir, _) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        transport.suspend = true
        sync.requestSync(reason: .manual); clock.advance(0); await settle()
        for _ in 0..<8 { sync.requestSync(reason: .eventChanged) }
        clock.advance(5); await settle()
        XCTAssertEqual(transport.snapshots.count, 1); XCTAssertTrue(sync.running)
        transport.resume(); await settle(); clock.advance(0); await settle()
        XCTAssertEqual(transport.snapshots.count, 2)
        transport.resume(); await settle(); XCTAssertFalse(sync.running)
    }
    func testPartialApplyReplansWithoutDuplicateAndSelfNotificationConverges() async throws {
        let (sync, provider, clock, transport, dir, _) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try sync.previewInitialPlan(); try sync.enableReviewedWrites()
        provider.failWriteAfterPersist = true
        sync.requestSync(reason: .manual); clock.advance(0); await settle()
        XCTAssertEqual(provider.writes, 1); XCTAssertEqual(transport.snapshots.count, 1); XCTAssertTrue(sync.failed)
        provider.failWriteAfterPersist = false
        clock.advance(5); await settle()
        XCTAssertEqual(provider.writes, 1); XCTAssertEqual(transport.snapshots.count, 2); XCTAssertFalse(sync.failed)
        sync.requestSync(reason: .eventChanged); clock.advance(5); await settle()
        clock.advance(5); await settle()
        XCTAssertEqual(provider.writes, 1); XCTAssertEqual(transport.snapshots.count, 3)
    }
    func testRestartRepairsFromPersistedOptInButChangedSettingsRevokeIt() async throws {
        let (sync, provider, clock, _, dir, settings) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try sync.previewInitialPlan(); try sync.enableReviewedWrites()
        let transport = TestTransport()
        let restarted = SyncCoordinator(adapter: EventKitAdapter(provider: provider, installationID: settings.installationID, receipts: try OwnershipReceiptStore(directoryURL: dir, installationID: settings.installationID)), settings: settings, directoryURL: dir, transport: transport, clock: clock)
        XCTAssertTrue(restarted.writesEnabled)
        restarted.start(); clock.advance(0); await settle()
        XCTAssertEqual(provider.writes, 1)
        clock.advance(300); await settle(); XCTAssertEqual(transport.snapshots.count, 2)
        restarted.requestSync(reason: .wake); clock.advance(0); await settle(); XCTAssertEqual(transport.snapshots.count, 3)
        var edited = settings; edited.lookaheadDays = 1
        try restarted.updateSettings(edited); XCTAssertFalse(restarted.writesEnabled)
        restarted.stop(); clock.advance(600); await settle(); XCTAssertEqual(transport.snapshots.count, 3)
    }
    func testFailedTransportRetainsLastSuccessfulTimestampAndRetries() async throws {
        let (sync, _, clock, transport, dir, _) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        sync.requestSync(reason: .manual); clock.advance(0); await settle()
        let success = try XCTUnwrap(sync.lastSuccessfulSync)
        transport.fail = true; clock.advance(10)
        sync.requestSync(reason: .wake); clock.advance(0); await settle()
        XCTAssertEqual(sync.lastSuccessfulSync, success); XCTAssertTrue(sync.failed)
        transport.fail = false; clock.advance(5); await settle()
        XCTAssertFalse(sync.failed); XCTAssertGreaterThan(try XCTUnwrap(sync.lastSuccessfulSync), success)
    }
    func testIncompletePreviewCannotEnableWritesAndRevokedAccessDoesNotApply() async throws {
        let (sync, provider, clock, _, dir, _) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        provider.failRead = true; XCTAssertThrowsError(try sync.previewInitialPlan()); XCTAssertThrowsError(try sync.enableReviewedWrites())
        provider.failRead = false; _ = try sync.previewInitialPlan(); try sync.enableReviewedWrites()
        provider.access = .denied
        sync.requestSync(reason: .manual); clock.advance(0); await settle()
        XCTAssertEqual(provider.writes, 0); XCTAssertTrue(sync.failed)
    }
    func testTransportFailureDoesNotBlockReviewedLocalReconciliation() async throws {
        let (sync, provider, clock, transport, dir, _) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try sync.previewInitialPlan(); try sync.enableReviewedWrites()
        transport.fail = true; sync.requestSync(reason: .manual); clock.advance(0); await settle()
        XCTAssertEqual(provider.writes, 1); XCTAssertNil(sync.lastSuccessfulSync); XCTAssertTrue(sync.failed)
        transport.fail = false; clock.advance(5); await settle()
        XCTAssertEqual(provider.writes, 1); XCTAssertNotNil(sync.lastSuccessfulSync); XCTAssertFalse(sync.failed)
    }
    func testRestartWithIncompleteReadsRetainsExportHealthAndNeverWrites() async throws {
        let (sync, provider, clock, _, dir, settings) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try sync.previewInitialPlan(); try sync.enableReviewedWrites(); provider.failRead = true
        let transport = TestTransport()
        let restarted = SyncCoordinator(adapter: EventKitAdapter(provider: provider, installationID: settings.installationID), settings: settings, directoryURL: dir, transport: transport, clock: clock)
        restarted.start(); clock.advance(0); await settle()
        XCTAssertEqual(provider.writes, 0); XCTAssertTrue(restarted.failed)
        XCTAssertEqual(transport.snapshots.first?.calendars.first?.localHealth, .failed)
        XCTAssertNil(transport.snapshots.first?.calendars.first?.events)
        restarted.stop()
    }
    func testOwnershipRejectsSymlinkAndCorruptWriteIntentNeverEnables() throws {
        let (sync, provider, clock, transport, dir, settings) = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = sync
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("process.lock"), withDestinationURL: dir.appendingPathComponent("settings.json"))
        XCTAssertThrowsError(try ProcessOwnership(directoryURL: dir))
        try AtomicStore(fileURL: dir.appendingPathComponent("write-intent.json")).save(Data("corrupt".utf8))
        let restarted = SyncCoordinator(adapter: EventKitAdapter(provider: provider, installationID: settings.installationID), settings: settings, directoryURL: dir, transport: transport, clock: clock)
        XCTAssertFalse(restarted.writesEnabled); XCTAssertTrue(restarted.failed)
    }
    func testProcessOwnershipAllowsOnlyOneOwner() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("owner-\(UUID())"); defer { try? FileManager.default.removeItem(at: dir) }
        var first: ProcessOwnership? = try ProcessOwnership(directoryURL: dir)
        XCTAssertThrowsError(try ProcessOwnership(directoryURL: dir))
        first = nil
        let next = try ProcessOwnership(directoryURL: dir); withExtendedLifetime(next) {}
        _ = first
    }
}
@MainActor final class TestSyncClock: SyncClock {
    var now = Date(timeIntervalSince1970: 100)
    var jobs: [(Date, SyncCancellation, @MainActor () -> Void)] = []
    func schedule(after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> SyncCancellation {
        let cancellation = SyncCancellation(); jobs.append((now.addingTimeInterval(seconds), cancellation, action)); return cancellation
    }
    func advance(_ seconds: TimeInterval) {
        now.addTimeInterval(seconds)
        let ready = jobs.filter { $0.0 <= now }; jobs.removeAll { $0.0 <= now }
        for (_, token, action) in ready where !token.cancelled { action() }
    }
}
@MainActor final class TestTransport: SnapshotTransport {
    var snapshots: [CalendarSnapshot] = []; var fail = false; var suspend = false
    var continuation: CheckedContinuation<Void, Never>?
    func send(snapshot: CalendarSnapshot) async throws {
        snapshots.append(snapshot)
        if suspend { await withCheckedContinuation { continuation = $0 } }
        if fail { throw SSHTransportError.failed }
    }
    func resume() { continuation?.resume(); continuation = nil }
}
