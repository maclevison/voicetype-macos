import CryptoKit
import Foundation

/// Vault-relative paths (`p5/decisoes/x.md`, always `/`-separated) and the
/// helpers that guard them.
public enum OKPath {
    /// A knowledge doc of `project`: exactly `<project>/<type folder>/<file>.md`,
    /// with no `..`, hidden file, backslash, control character or subfolder.
    /// Anything else (as a path proposed by the model) → `nil`.
    public static func knowledgeDoc(_ relPath: String, project: String) -> (type: OKKnowledgeType, file: String)? {
        guard !relPath.contains("\\"), !relPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let parts = relPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == project, let type = OKKnowledgeType(folder: parts[1]) else { return nil }
        let file = parts[2]
        guard file.hasSuffix(".md"), file.count > 3, !file.hasPrefix(".") else { return nil }
        return (type, file)
    }

    /// The relative Markdown link from the doc at `from` to the doc at `to`,
    /// both vault-relative.
    public static func relativeLink(from: String, to: String) -> String {
        let fromDir = from.split(separator: "/").dropLast()
        let target = to.split(separator: "/")
        var common = 0
        while common < fromDir.count, common < target.count - 1,
              fromDir[fromDir.startIndex + common] == target[common] {
            common += 1
        }
        let ups = Array(repeating: "..", count: fromDir.count - common)
        return (ups + target[common...].map(String.init)).joined(separator: "/")
    }

    /// Lowercase hex SHA-256: how the app recognises a doc it read before.
    public static func contentHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `<base>.md`, else `<base>-2.md`, `<base>-3.md`…, stopping early at a
    /// file whose frontmatter carries `id: <id>` (our own earlier write).
    public static func uniqueDestination(base: String, id: UUID, in directory: URL, fileManager: FileManager = .default) -> URL {
        var n = 1
        while true {
            let url = directory.appendingPathComponent(n == 1 ? "\(base).md" : "\(base)-\(n).md")
            if !fileManager.fileExists(atPath: url.path) || MeetingNoteWriter.belongs(url, to: id) { return url }
            n += 1
        }
    }
}
