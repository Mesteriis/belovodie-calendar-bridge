import Foundation
import Darwin
import BridgeCore

public enum SSHTransportError: Error { case invalidConfiguration, unavailable, failed, timedOut }
public struct SSHConfiguration: Codable, Sendable {
    public let hostAlias: String
    public let identityFile: String
    public let knownHostsFile: String
    public let port: Int
    public let configFile: String?
    public init(hostAlias: String, identityFile: String, knownHostsFile: String, port: Int = 22, configFile: String? = nil) throws {
        self.hostAlias = hostAlias; self.identityFile = identityFile; self.knownHostsFile = knownHostsFile; self.port = port; self.configFile = configFile
        try validate()
    }
    private enum CodingKeys: String, CodingKey { case hostAlias, identityFile, knownHostsFile, port, configFile }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(hostAlias: values.decode(String.self, forKey: .hostAlias),
                      identityFile: values.decode(String.self, forKey: .identityFile),
                      knownHostsFile: values.decode(String.self, forKey: .knownHostsFile),
                      port: values.decodeIfPresent(Int.self, forKey: .port) ?? 22,
                      configFile: values.decodeIfPresent(String.self, forKey: .configFile))
    }
    func validate() throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !hostAlias.isEmpty, !hostAlias.hasPrefix("-"), hostAlias.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              (1...65535).contains(port), ([identityFile, knownHostsFile] + [configFile].compactMap { $0 }).allSatisfy({ $0.hasPrefix("/") && !$0.contains("\n") && !$0.contains("\0") && !$0.contains("\"") && !$0.contains("\\") }) else { throw SSHTransportError.invalidConfiguration }
    }
    public static func load(directoryURL: URL) throws -> SSHConfiguration {
        guard let data = try AtomicStore(fileURL: directoryURL.appendingPathComponent("ssh.json")).load() else { throw SSHTransportError.unavailable }
        let config = try JSONDecoder().decode(Self.self, from: data); try config.validate(); return config
    }
}
public struct SSHProcessResult: Sendable {
    public let exitCode: Int32
    public let timedOut: Bool
    public init(exitCode: Int32, timedOut: Bool) { self.exitCode = exitCode; self.timedOut = timedOut }
}
@MainActor public protocol SSHProcessRunner {
    func run(executable: String, arguments: [String], stdin: Data, timeout: TimeInterval) async throws -> SSHProcessResult
}
private final class InputWriteResult: @unchecked Sendable {
    private let lock = NSLock()
    private var failure = false
    func markFailed() { lock.lock(); failure = true; lock.unlock() }
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return failure }
}
@MainActor public struct NativeSSHProcessRunner: SSHProcessRunner {
    public init() {}
    public func run(executable: String, arguments: [String], stdin: Data, timeout: TimeInterval) async throws -> SSHProcessResult {
        guard timeout > 0, timeout.isFinite else { throw SSHTransportError.invalidConfiguration }
        return try await Task.detached { try Self.execute(executable: executable, arguments: arguments, stdin: stdin, timeout: timeout) }.value
    }
    nonisolated private static func execute(executable: String, arguments: [String], stdin: Data, timeout: TimeInterval) throws -> SSHProcessResult {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let input = Pipe(); process.standardInput = input
        // Neither process output stream is retained or logged: remote failures can contain event data.
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        // Child owns the read end after launch; retaining it here can deadlock a blocked writer.
        try input.fileHandleForReading.close()
        let writer = DispatchGroup(); writer.enter(); let inputResult = InputWriteResult()
        DispatchQueue.global().async {
            defer {
                do { try input.fileHandleForWriting.close() } catch { inputResult.markFailed() }
                writer.leave()
            }
            // Darwin suppresses SIGPIPE on this descriptor, without global signal state.
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else { inputResult.markFailed(); return }
            stdin.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(input.fileHandleForWriting.fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    if count <= 0 { inputResult.markFailed(); break }
                    offset += count
                }
            }
        }
        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL); exited.wait()
            }
        }
        process.waitUntilExit(); writer.wait()
        if inputResult.failed && !timedOut { throw SSHTransportError.failed }
        return SSHProcessResult(exitCode: process.terminationStatus, timedOut: timedOut)
    }
}
@MainActor public struct SSHTransport: SnapshotTransport {
    public static let receiverCommand = "docker exec -i homeassistant python /config/_tools/belovodie_calendar_bridge/ha_ssh_receiver.py"
    private let configuration: SSHConfiguration
    private let runner: any SSHProcessRunner
    public init(configuration: SSHConfiguration, runner: any SSHProcessRunner = NativeSSHProcessRunner()) {
        self.configuration = configuration; self.runner = runner
    }
    public func send(snapshot: CalendarSnapshot) async throws {
        try configuration.validate()
        guard snapshot.version == 1 else { throw SSHTransportError.failed }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let result = try await runner.run(executable: "/usr/bin/ssh", arguments: [
            "-F", configuration.configFile ?? "/dev/null", "-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2", "-o", "PermitLocalCommand=no", "-o", "ProxyCommand=none",
            "-o", "ProxyJump=none", "-o", "ControlMaster=no", "-o", "ControlPath=none",
            "-o", "UserKnownHostsFile=\"\(configuration.knownHostsFile)\"", "-i", configuration.identityFile,
            "-p", String(configuration.port), "--", configuration.hostAlias, Self.receiverCommand
        ], stdin: try encoder.encode(snapshot), timeout: 30)
        guard !result.timedOut else { throw SSHTransportError.timedOut }
        guard result.exitCode == 0 else { throw SSHTransportError.failed }
    }
}
@MainActor public struct UnconfiguredTransport: SnapshotTransport {
    public init() {}
    public func send(snapshot: CalendarSnapshot) async throws { throw SSHTransportError.unavailable }
}
