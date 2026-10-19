import Foundation

/// Where meeting notes and voice notes go: the Obsidian folder (unchanged
/// behavior) or an OpenKnowledge project.
public enum MeetingVaultKind: String, Codable, Sendable, CaseIterable {
    case obsidian
    case openKnowledge = "openknowledge"
}

public enum OKVault {
    /// Stands for "no vault configured". `/dev/null/.ok` can never exist, so
    /// it never passes `isProjectRoot` (an empty path would otherwise resolve
    /// to the process's working directory).
    public static let unset = URL(fileURLWithPath: "/dev/null", isDirectory: true)

    /// Whether a vault path was set at all (blank = not set).
    public static func isConfigured(_ path: String) -> Bool {
        !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The configured vault path with `~` expanded, as a directory URL;
    /// `unset` when the path is blank.
    public static func url(_ path: String) -> URL {
        guard isConfigured(path) else { return unset }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// An OpenKnowledge project root holds a `.ok/` directory (a plain file
    /// named `.ok` doesn't count).
    public static func isProjectRoot(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.appendingPathComponent(".ok").path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }
}

/// Which vault a proposal, an approval or a journal belongs to: the canonical
/// root path plus the root's device and inode. Nothing is written inside the
/// vault to identify it, so a vault deleted and recreated in the same place
/// (new inode) or another `.ok/` folder never matches.
public struct OKVaultIdentity: Codable, Equatable, Sendable {
    /// Standardized, symlinks resolved.
    public var root: String
    public var device: UInt64
    public var inode: UInt64

    public init(root: String, device: UInt64, inode: UInt64) {
        self.root = root
        self.device = device
        self.inode = inode
    }

    /// Throws when `vault` isn't an OpenKnowledge project root (no `.ok/`)
    /// or can't be `stat`ed.
    public static func of(_ vault: URL) throws -> OKVaultIdentity {
        let root = vault.standardizedFileURL.resolvingSymlinksInPath().path
        guard OKVault.isProjectRoot(URL(fileURLWithPath: root, isDirectory: true)) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: vault.path])
        }
        var info = stat()
        guard stat(root, &info) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return OKVaultIdentity(root: root, device: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino))
    }

    /// Same canonical path and same device + inode.
    public func matches(_ vault: URL) -> Bool {
        (try? Self.of(vault)) == self
    }
}
