import Foundation
import Darwin
import BridgeCore

public enum ProcessOwnershipError: Error { case unavailable, alreadyRunning }
/// A kernel-held lock survives file contents and is automatically released on process exit.
public final class ProcessOwnership {
    private let descriptor: Int32
    public init(directoryURL: URL) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // AtomicStore validates/tightens the private directory without reading provider state.
        _ = try AtomicStore(fileURL: directoryURL.appendingPathComponent("process.lock")).load()
        let path = directoryURL.appendingPathComponent("process.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProcessOwnershipError.unavailable }
        var stat = stat()
        guard fstat(fd, &stat) == 0, stat.st_mode & S_IFMT == S_IFREG, stat.st_nlink == 1,
              fchmod(fd, 0o600) == 0 else { close(fd); throw ProcessOwnershipError.unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw ProcessOwnershipError.alreadyRunning }
        descriptor = fd
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
