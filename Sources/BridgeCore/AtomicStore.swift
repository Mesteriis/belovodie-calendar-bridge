import Darwin
import Foundation

public enum AtomicStoreError: Error, Equatable {
    case unsafePath
    case system(Int32)
}

/// Private local storage; callers serialize access. Incomplete temporary files are never loaded.
public struct AtomicStore: Sendable {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() throws -> Data? {
        let directory = try openDirectory(create: false)
        guard let directory else { return nil }
        defer { close(directory) }
        guard try checkFile(directory, name: fileURL.lastPathComponent) else { return nil }
        let file = openat(directory, fileURL.lastPathComponent, O_RDONLY | O_NOFOLLOW)
        guard file >= 0 else { throw AtomicStoreError.system(errno) }
        defer { close(file) }
        try secureFile(file)
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(file, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw AtomicStoreError.system(errno)
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    public func save(_ data: Data) throws {
        let directory = try openDirectory(create: true)!
        defer { close(directory) }
        _ = try checkFile(directory, name: fileURL.lastPathComponent)
        let temporary = ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard file >= 0 else { throw AtomicStoreError.system(errno) }
        defer { close(file); unlinkat(directory, temporary, 0) }
        try secureFile(file)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw AtomicStoreError.system(errno)
                }
                guard count > 0 else { throw AtomicStoreError.system(EIO) }
                offset += count
            }
        }
        guard fsync(file) == 0 else { throw AtomicStoreError.system(errno) }
        _ = try checkFile(directory, name: fileURL.lastPathComponent)
        guard renameat(directory, temporary, directory, fileURL.lastPathComponent) == 0 else {
            throw AtomicStoreError.system(errno)
        }
        guard fsync(directory) == 0 else { throw AtomicStoreError.system(errno) }
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        guard fileURL.isFileURL, !["", ".", ".."].contains(fileURL.lastPathComponent) else { throw AtomicStoreError.unsafePath }
        let url = fileURL.deletingLastPathComponent()
        if create {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
        let directory = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if directory < 0 {
            if errno == ENOENT && !create { return nil }
            throw AtomicStoreError.system(errno)
        }
        guard fchmod(directory, mode_t(0o700)) == 0 else {
            let code = errno; close(directory); throw AtomicStoreError.system(code)
        }
        return directory
    }

    /// Never follow a symlink or accept a directory/device/hard-linked private file.
    private func checkFile(_ directory: Int32, name: String) throws -> Bool {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return false }
            throw AtomicStoreError.system(errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw AtomicStoreError.unsafePath }
        return true
    }
    private func secureFile(_ file: Int32) throws {
        var info = stat()
        guard fstat(file, &info) == 0 else { throw AtomicStoreError.system(errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else { throw AtomicStoreError.unsafePath }
        guard fchmod(file, mode_t(0o600)) == 0 else { throw AtomicStoreError.system(errno) }
    }
}
