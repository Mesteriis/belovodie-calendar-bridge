import Foundation
import XCTest
@testable import BridgeCore

final class SettingsStoreTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-tests-\(UUID())", isDirectory: true)
    }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
    func descriptor(_ id: String, name: String) -> CalendarDescriptor {
        CalendarDescriptor(sourceID: "source", calendarID: id, name: name, owner: "Owner", timeZoneID: "Europe/Madrid", localRead: .missing)
    }
    func testInstallationAndChoicesPersistAcrossRunsAndCalendarRename() throws {
        let store = SettingsStore(directoryURL: directory)
        var settings = try store.load()
        settings.discover([descriptor("a", name: "Original")])
        XCTAssertEqual(settings.policies.count, 1)
        guard !settings.policies.isEmpty else { return }
        settings.policies[0].exportToHA = true; settings.policies[0].busyTarget = true
        settings.policies[0].label = "Chosen label"
        try store.save(settings)
        var loaded = try SettingsStore(directoryURL: directory).load()
        XCTAssertEqual(loaded, settings)
        loaded.discover([descriptor("a", name: "Renamed"), descriptor("b", name: "New")])
        XCTAssertEqual(loaded.policies[0], settings.policies[0])
        let new = try XCTUnwrap(loaded.policies.last)
        XCTAssertFalse(new.exportToHA); XCTAssertFalse(new.busySource); XCTAssertFalse(new.busyTarget)
        loaded.discover([])
        XCTAssertEqual(loaded.policies.count, 2)
    }
    func testFirstLoadPersistsUUIDAndCreatesPrivatePaths() throws {
        let store = SettingsStore(directoryURL: directory)
        let first = try store.load()
        XCTAssertEqual(try store.load().installationID, first.installationID)
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(directory.appendingPathComponent("settings.json")), 0o600)
    }
    func testCorruptionIsVisibleAndDoesNotRegenerateIdentity() throws {
        let store = SettingsStore(directoryURL: directory)
        _ = try store.load()
        let file = directory.appendingPathComponent("settings.json")
        try Data("{broken".utf8).write(to: file)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: file), Data("{broken".utf8))
    }
    func testAtomicSaveRetainsPreviousCompleteStateWithInterruptedTemporaryFile() throws {
        let store = SettingsStore(directoryURL: directory)
        var settings = try store.load()
        settings.policies = [CalendarPolicy(sourceID: "source", calendarID: "a", owner: "Owner", label: "First", exportToHA: true)]
        try store.save(settings)
        try Data("{unfinished".utf8).write(to: directory.appendingPathComponent(".settings.json.interrupted.tmp"))
        XCTAssertEqual(try store.load(), settings)
        settings.policies[0].label = "Second"
        try store.save(settings)
        XCTAssertEqual(try store.load(), settings)
        XCTAssertEqual(try permissions(directory.appendingPathComponent("settings.json")), 0o600)
    }
    func testAtomicStoreMissingLoadRoundTripAndRejectsSymlink() throws {
        let file = directory.appendingPathComponent("data.json")
        let store = AtomicStore(fileURL: file)
        XCTAssertNil(try store.load())
        try store.save(Data("first".utf8))
        XCTAssertEqual(try store.load(), Data("first".utf8))
        let other = directory.appendingPathComponent("other")
        try Data("untouched".utf8).write(to: other)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(Data("replacement".utf8)))
        XCTAssertEqual(try Data(contentsOf: other), Data("untouched".utf8))
    }
    func testUnsupportedVersionAndDuplicatePoliciesFailWithoutReplacingSettings() throws {
        let store = SettingsStore(directoryURL: directory)
        let original = try store.load()
        let policy = CalendarPolicy(sourceID: "source", calendarID: "a", owner: "Owner", label: "Label")
        let invalid = BridgeSettings(installationID: original.installationID, policies: [policy, policy])
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try store.load(), original)
        let file = directory.appendingPathComponent("settings.json")
        let validData = try Data(contentsOf: file)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: validData) as? [String: Any])
        object["version"] = 2
        let unsupported = try JSONSerialization.data(withJSONObject: object)
        try unsupported.write(to: file)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: file), unsupported)
    }
    func testHardLinkedDestinationAndSymlinkDirectoryAreRejected() throws {
        let file = directory.appendingPathComponent("data")
        let store = AtomicStore(fileURL: file)
        try store.save(Data("complete".utf8))
        try FileManager.default.linkItem(at: file, to: directory.appendingPathComponent("hardlink"))
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(Data("replacement".utf8)))
        XCTAssertEqual(try Data(contentsOf: file), Data("complete".utf8))
        let linked = directory.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: directory)
        let unsafe = AtomicStore(fileURL: linked.appendingPathComponent("other"))
        XCTAssertThrowsError(try unsafe.load())
        XCTAssertThrowsError(try unsafe.save(Data()))
    }
    private func permissions(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue
    }
}
