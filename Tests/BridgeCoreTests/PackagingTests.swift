import Foundation
import XCTest

final class PackagingTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private let calendarEntitlement = "com.apple.security.personal-information.calendars"
    func testRequestedEntitlementsAreLimitedToCalendarAccess() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("packaging/Entitlements.plist"))
        let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Bool])
        XCTAssertEqual(values, [calendarEntitlement: true])
    }
    func testSignedBundleCarriesCalendarEntitlementAndHardenedRuntime() throws {
        let app = root.appendingPathComponent("build/BelovodieCalendarBridge.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("Build app bundle before signature regression verification") }
        let entitlements = try command(["-d", "--entitlements", ":-", app.path]).stdout
        let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: entitlements, format: nil) as? [String: Bool])
        XCTAssertEqual(values, [calendarEntitlement: true])
        let details = try command(["-d", "--verbose=4", app.path]).stderr
        // Inspect private signing metadata in memory; never print signer/certificate details.
        let flags = String(decoding: details, as: UTF8.self).split(separator: "\n").first { $0.contains("flags=") }
        XCTAssertTrue(flags?.contains("runtime") == true, "Signed bundle must enable hardened runtime")
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.belovodie.calendar-bridge")
        XCTAssertEqual(info["LSMinimumSystemVersion"] as? String, "14.0")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "BelovodieCalendarBridge")
        XCTAssertFalse((info["NSCalendarsFullAccessUsageDescription"] as? String ?? "").isEmpty)
        _ = try command(["--verify", "--strict", app.path])
    }
    private func command(_ arguments: [String]) throws -> (stdout: Data, stderr: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        let output = Pipe(); let error = Pipe()
        process.standardOutput = output; process.standardError = error
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Code-signing verification command must succeed")
        return (stdout, stderr)
    }
}
