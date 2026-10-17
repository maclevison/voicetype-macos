import Darwin
import Foundation

/// Writes that survive a power cut: `F_FULLFSYNC` flushes the drive's cache,
/// which a plain `fsync` on macOS doesn't.
enum OKDurableFile {
    /// Creates (or truncates) `url`, writes `data` and flushes it to the disk.
    static func write(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                offset += n
            }
        }
        try fullSync(fd)
    }

    /// Flushes a directory, so the renames and creations inside it are on disk.
    static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        try fullSync(fd)
    }

    /// `F_FULLFSYNC`, falling back to `fsync` on file systems without it.
    private static func fullSync(_ fd: Int32) throws {
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        guard fsync(fd) == 0 else { throw posixError() }
    }

    static func posixError(_ code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
