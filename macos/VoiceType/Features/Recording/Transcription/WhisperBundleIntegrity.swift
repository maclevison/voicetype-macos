import Foundation
import CryptoKit

/// Checks a downloaded WhisperKit model against the hashes its downloader
/// recorded in `<metadataFolder>/<path>.metadata` (line 2: the etag, a SHA-256
/// for LFS files, the git blob SHA-1 for the others). Core ML crashes the app,
/// it does not throw, on truncated or corrupted weights, so every load checks
/// the bundle first. Hashing a 632 MB model takes about 0.3 s.
enum WhisperBundleIntegrity {
    /// Paths, relative to `folder`, of the files that are missing or whose
    /// content does not match their record (or that have none). A file is
    /// expected when it is on disk, has a record (records outlive a deleted
    /// file), or is listed in `expected` (the inventory of the completion
    /// marker, which outlives a file deleted with its record). Files named in
    /// `ignoring` are skipped.
    static func damagedFiles(
        in folder: URL, metadataFolder: URL, expected: Set<String>, ignoring: Set<String>
    ) async -> [String] {
        let present = Set(files(in: folder))
        let recorded = Set(files(in: metadataFolder).compactMap { path in
            path.hasSuffix(".metadata") ? String(path.dropLast(".metadata".count)) : nil
        })
        var damaged: [String] = []
        for relative in present.union(recorded).union(expected).subtracting(ignoring).sorted() {
            guard !Task.isCancelled else { break }
            let file = folder.appendingPathComponent(relative)
            let record = metadataFolder.appendingPathComponent(relative + ".metadata")
            if !present.contains(relative) || etag(in: record).map({ matches(file, etag: $0) }) != true {
                damaged.append(relative)
            }
        }
        return damaged
    }

    /// Paths, relative to `folder`, of its regular files.
    static func files(in folder: URL) -> [String] {
        let base = folder.resolvingSymlinksInPath().pathComponents
        guard let files = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        var regular: [String] = []
        for case let file as URL in files
        where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            regular.append(file.resolvingSymlinksInPath().pathComponents.dropFirst(base.count).joined(separator: "/"))
        }
        return regular
    }

    private static func etag(in record: URL) -> String? {
        guard let text = try? String(contentsOf: record, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: .newlines)
        return lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespaces) : nil
    }

    private static func matches(_ file: URL, etag: String) -> Bool {
        switch etag.count {
        case 64:
            var hasher = SHA256()
            guard stream(file, into: { hasher.update(data: $0) }) else { return false }
            return hex(hasher.finalize()) == etag
        case 40:
            guard let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int else { return false }
            var hasher = Insecure.SHA1()
            hasher.update(data: Data("blob \(size)\0".utf8))
            guard stream(file, into: { hasher.update(data: $0) }) else { return false }
            return hex(hasher.finalize()) == etag
        default:
            return false
        }
    }

    private static func stream(_ file: URL, into update: (Data) -> Void) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        do {
            // nil (or empty) at the end of the file.
            while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
                update(chunk)
            }
            return true
        } catch {
            return false
        }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
