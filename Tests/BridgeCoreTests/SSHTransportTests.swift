import Foundation
import XCTest
@testable import BridgeCore
@testable import BridgeMac

@MainActor final class SSHTransportTests: XCTestCase {
    func testPayloadOnlyOnStdinAndStrictClosedCommand() async throws {
        let runner = CapturingSSHRunner()
        let config = try SSHConfiguration(hostAlias: "bridge-test", identityFile: "/tmp/test-key", knownHostsFile: "/tmp/test-hosts")
        let transport = SSHTransport(configuration: config, runner: runner)
        let snapshot = try SnapshotBuilder(installationID: UUID()).build(events: [], policies: [], inventory: [], window: QueryWindow(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 10)), observedAt: Date(timeIntervalSince1970: 1))
        try await transport.send(snapshot: snapshot)
        XCTAssertEqual(try JSONDecoder().decode(CalendarSnapshot.self, from: runner.payload), snapshot)
        XCTAssertEqual(runner.executable, "/usr/bin/ssh")
        XCTAssertEqual(runner.arguments.last, SSHTransport.receiverCommand)
        XCTAssertTrue(runner.arguments.contains("StrictHostKeyChecking=yes")); XCTAssertTrue(runner.arguments.contains("BatchMode=yes"))
        XCTAssertFalse(runner.arguments.contains { $0.contains("observedAt") })
        runner.result = SSHProcessResult(exitCode: 1, timedOut: false)
        do { try await transport.send(snapshot: snapshot); XCTFail("Nonzero exit must fail") } catch {}
        runner.result = SSHProcessResult(exitCode: 0, timedOut: true)
        do { try await transport.send(snapshot: snapshot); XCTFail("Timeout must fail even after exit zero") } catch {}
        XCTAssertThrowsError(try SSHConfiguration(hostAlias: "-oProxyCommand=evil", identityFile: "/tmp/key", knownHostsFile: "/tmp/hosts"))
        XCTAssertThrowsError(try SSHConfiguration(hostAlias: "host;echo evil", identityFile: "/tmp/key", knownHostsFile: "/tmp/hosts"))
    }
    func testPrivateConfigurationDefaultsPortAndRejectsMalformedHost() throws {
        let data = Data(#"{"hostAlias":"bridge-test","identityFile":"/tmp/test-key","knownHostsFile":"/tmp/test hosts"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SSHConfiguration.self, from: data).port, 22)
        let unsafe = Data(#"{"hostAlias":"-oProxyCommand=bad","identityFile":"/tmp/key","knownHostsFile":"/tmp/hosts"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(SSHConfiguration.self, from: unsafe))
    }
    func testRealProcessRunnerClosesStdinAndEnforcesTimeout() async throws {
        let runner = NativeSSHProcessRunner()
        let result = try await runner.run(executable: "/usr/bin/python3", arguments: ["-c", "import sys; data=sys.stdin.buffer.read(); sys.exit(0 if data == b'payload' else 7)"], stdin: Data("payload".utf8), timeout: 5)
        XCTAssertEqual(result.exitCode, 0); XCTAssertFalse(result.timedOut)
        let hung = try await runner.run(executable: "/bin/sleep", arguments: ["5"], stdin: Data(repeating: 65, count: 1024 * 1024), timeout: 0.05)
        XCTAssertTrue(hung.timedOut)
    }
}
@MainActor final class CapturingSSHRunner: SSHProcessRunner {
    var executable = ""; var arguments: [String] = []; var payload = Data()
    var result = SSHProcessResult(exitCode: 0, timedOut: false)
    func run(executable: String, arguments: [String], stdin: Data, timeout: TimeInterval) async throws -> SSHProcessResult {
        self.executable = executable; self.arguments = arguments; payload = stdin; return result
    }
}
