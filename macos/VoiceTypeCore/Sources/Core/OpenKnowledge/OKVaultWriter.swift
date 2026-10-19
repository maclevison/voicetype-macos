import Darwin
import Foundation

/// One approved change to a vault file. Paths are vault-relative.
public enum OKVaultOp: Codable, Equatable, Sendable {
    case create(path: String, content: String, itemID: UUID?)
    case update(path: String, content: String, expectedHash: String, itemID: UUID?)
    /// Folder metadata (`.ok/frontmatter.yml`): written only when missing.
    case createIfMissing(path: String, content: String)

    public var path: String {
        switch self {
        case let .create(path, _, _), let .update(path, _, _, _), let .createIfMissing(path, _): path
        }
    }
}

/// A file that didn't match what the user approved. `currentContent` and
/// `currentHash` are `nil` when the file is gone.
public struct OKConflict: Codable, Equatable, Sendable {
    public var itemID: UUID?
    public var path: String
    public var currentContent: String?
    public var currentHash: String?

    public init(itemID: UUID?, path: String, currentContent: String?, currentHash: String?) {
        self.itemID = itemID
        self.path = path
        self.currentContent = currentContent
        self.currentHash = currentHash
    }
}

/// Proof that a meeting's approval reached the vault. `written` lists the
/// destinations holding our content or a later version of it.
public struct OKCommitReceipt: Codable, Equatable, Sendable {
    public var meetingID: UUID
    public var proposalGeneration: UUID
    public var vault: OKVaultIdentity
    public var project: String
    public var paths: OKMeetingPaths
    public var written: [String]

    public init(meetingID: UUID, proposalGeneration: UUID, vault: OKVaultIdentity, project: String, paths: OKMeetingPaths, written: [String] = []) {
        self.meetingID = meetingID
        self.proposalGeneration = proposalGeneration
        self.vault = vault
        self.project = project
        self.paths = paths
        self.written = written
    }
}

/// A version written by someone else that the transaction took out of a
/// destination and kept instead of deleting.
public struct OKDivergence: Codable, Equatable, Sendable {
    public var path: String
    /// Absolute path of the kept copy.
    public var preservedCopy: String?
    public var reason: String

    public init(path: String, preservedCopy: String?, reason: String) {
        self.path = path
        self.preservedCopy = preservedCopy
        self.reason = reason
    }
}

public enum OKCommitResult: Equatable, Sendable {
    case committed(OKCommitReceipt)
    case partial(OKCommitReceipt, conflicts: [OKConflict], divergences: [OKDivergence])
    case conflicts([OKConflict], divergences: [OKDivergence])
    case preconditionFailed
}

public enum OKRecoveryOutcome: Equatable, Sendable {
    case nothing
    case committed(OKCommitReceipt)
    case partial(OKCommitReceipt, conflicts: [OKConflict], divergences: [OKDivergence])
    case rolledBack(conflicts: [OKConflict], divergences: [OKDivergence])
    case vaultUnavailable(root: String)
}

/// Where the test hook runs. Indices are positions in the `ops` passed to
/// `commit` (dependencies for `forwardBeforeRestoreDependency`);
/// `cleanupBeforeDelete` carries the staging file name (`pre-0`, `copy-1`…).
public enum OKFaultPoint: Equatable, Sendable {
    case afterPrepare, beforeApply(Int), afterSwap(Int), afterApply(Int), afterReceipt,
         rollbackBeforeUndo(Int), rollbackAfterUndo(Int), afterRollback(Int),
         forwardBeforeApply(Int), forwardBeforeRestore(Int), forwardBeforeRestoreDependency(Int),
         cleanupBeforeDelete(String)
}

/// Thrown by a test hook to simulate the process dying: the writer leaves
/// the disk exactly as it is.
public struct OKSimulatedCrash: Error {
    public init() {}
}

/// The only way the app writes meetings into an OpenKnowledge vault: a
/// durable intent (journal) first, then conditional renames. Updates are
/// swapped in with `RENAME_SWAP` and the version that came out is checked,
/// every version that was in a destination is kept, and the state of each op
/// is derived from the files on disk, so a crash at any point is finished or
/// undone by `recover`.
///
/// Rollback only undoes what is still exactly our content. When a
/// destination holds a version someone wrote after ours (it may link to the
/// meeting's other new files), the transaction is completed instead: every
/// op was already approved, and completing is the only state without broken
/// links.
public struct OKVaultWriter: Sendable {
    public enum WriteError: Error, Equatable {
        case invalidPath(String)
        case vaultMismatch
        /// Completion was interrupted (disk error, or a destination that
        /// couldn't be restored); the journal stays in `rollingForward`.
        case incomplete([String])
    }

    private let vault: URL
    private let identity: OKVaultIdentity
    private let journalDirectory: URL
    /// Test hook, `nil` in production.
    public var fault: (@Sendable (OKFaultPoint) throws -> Void)?

    public init(vault: URL, identity: OKVaultIdentity, journalDirectory: URL) {
        self.vault = vault
        self.identity = identity
        self.journalDirectory = journalDirectory
    }

    /// Writes `ops` as one transaction. `dependencies` are vault-relative
    /// files the transaction doesn't write but that must exist when it ends
    /// (its files link to them). `precondition` runs after the staging is
    /// prepared and before the first rename; `false` writes nothing.
    /// On `.committed`/`.partial` the journal stays until `finish`.
    public func commit(
        _ ops: [OKVaultOp],
        dependencies: [String] = [],
        receipt: OKCommitReceipt,
        precondition: @Sendable () throws -> Bool
    ) throws -> OKCommitResult {
        guard identity.matches(vault) else { throw WriteError.vaultMismatch }
        let root = URL(fileURLWithPath: identity.root, isDirectory: true)
        let canonicalRoot = try Self.realPath(root.path)

        var seen = Set<String>()
        for op in ops {
            try Self.validate(op.path, root: root, canonicalRoot: canonicalRoot)
            guard seen.insert(op.path).inserted else { throw WriteError.invalidPath(op.path) }
        }
        for path in dependencies { try Self.validate(path, root: root, canonicalRoot: canonicalRoot) }

        // Validation, read-only.
        struct Planned { var index: Int; var kind: Journal.Kind; var path: String; var content: Data; var expectedHash: String?; var itemID: UUID? }
        var planned: [Planned] = []
        var deps = dependencies
        var conflicts: [OKConflict] = []
        for (index, op) in ops.enumerated() {
            let current = try Self.read(root.appendingPathComponent(op.path))
            switch op {
            case let .createIfMissing(path, content):
                if current == nil {
                    planned.append(Planned(index: index, kind: .create, path: path, content: Data(content.utf8)))
                } else {
                    deps.append(path)
                }
            case let .create(path, content, itemID):
                if let current {
                    conflicts.append(Self.conflict(itemID: itemID, path: path, data: current))
                } else {
                    planned.append(Planned(index: index, kind: .create, path: path, content: Data(content.utf8), itemID: itemID))
                }
            case let .update(path, content, expectedHash, itemID):
                let data = Data(content.utf8)
                guard let current else {
                    conflicts.append(Self.conflict(itemID: itemID, path: path, data: nil))
                    continue
                }
                if OKPath.contentHash(current) != expectedHash {
                    conflicts.append(Self.conflict(itemID: itemID, path: path, data: current))
                } else if OKPath.contentHash(data) == expectedHash {
                    deps.append(path)
                } else {
                    planned.append(Planned(index: index, kind: .update, path: path, content: data, expectedHash: expectedHash, itemID: itemID))
                }
            }
        }
        let opPaths = Set(planned.map(\.path))
        var depSeen = Set<String>()
        deps = deps.filter { !opPaths.contains($0) && depSeen.insert($0).inserted }
        var snapshots: [Data] = []
        for path in deps {
            if let data = try Self.read(root.appendingPathComponent(path)) {
                snapshots.append(data)
            } else {
                conflicts.append(Self.conflict(itemID: nil, path: path, data: nil))
            }
        }
        guard conflicts.isEmpty else { return .conflicts(conflicts, divergences: []) }

        // Preparation: staging, copies and the journal, before any destination changes.
        let txid = UUID()
        let staging = root.appendingPathComponent(".ok/local/voicetype-staging/\(txid.uuidString)", isDirectory: true)
        var journal = Journal(
            version: 1, txid: txid, vault: identity, staging: staging.path, receipt: receipt, phase: .prepared,
            ops: [], dependencies: []
        )
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for p in planned {
                var op = Journal.Op(
                    index: p.index, kind: p.kind, path: p.path, itemID: p.itemID,
                    tmp: "tmp-\(p.index)",
                    preimage: p.kind == .update ? "pre-\(p.index)" : nil,
                    removed: p.kind == .create ? "removed-\(p.index)" : nil,
                    copy: "copy-\(p.index)", restore: "restore-\(p.index)",
                    newHash: OKPath.contentHash(p.content), expectedHash: p.expectedHash,
                    createdDirs: Self.missingDirectories(of: p.path, root: root)
                )
                try OKDurableFile.write(p.content, to: staging.appendingPathComponent(op.tmp))
                op.tmpInode = try OKVaultTransaction.inode(staging.appendingPathComponent(op.tmp))
                try OKDurableFile.write(p.content, to: staging.appendingPathComponent(op.copy))
                journal.ops.append(op)
            }
            for (k, path) in deps.enumerated() {
                let dep = Journal.Dependency(path: path, snapshot: "dep-\(k)", snapshotHash: OKPath.contentHash(snapshots[k]), restore: "restore-dep-\(k)")
                try OKDurableFile.write(snapshots[k], to: staging.appendingPathComponent(dep.snapshot))
                journal.dependencies.append(dep)
            }
            try OKDurableFile.syncDirectory(staging)
            try OKDurableFile.syncDirectory(staging.deletingLastPathComponent())
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        let tx = OKVaultTransaction(journal: journal, journalDirectory: journalDirectory, fault: fault)
        do {
            try tx.saveJournal()
        } catch {
            try tx.discard()
            throw error
        }
        try tx.runFault(.afterPrepare)

        let proceed: Bool
        do {
            proceed = try precondition()
        } catch {
            try tx.discard()
            throw error
        }
        guard proceed else {
            try tx.discard()
            return .preconditionFailed
        }

        // Application.
        var hitConflict = false
        var trigger: (any Error)?
        do {
            for op in tx.journal.ops {
                try tx.runFault(.beforeApply(op.index))
                guard try tx.apply(op) else {
                    hitConflict = true
                    break
                }
                try tx.runFault(.afterApply(op.index))
            }
        } catch let crash as OKSimulatedCrash {
            throw crash
        } catch {
            trigger = error
        }

        let outcome: OKVaultTransaction.Outcome
        if hitConflict || trigger != nil {
            outcome = try tx.rollback()
            if case let .rolledBack(conflicts, divergences) = outcome {
                if let trigger, conflicts.isEmpty, divergences.isEmpty { throw trigger }
                return .conflicts(conflicts, divergences: divergences)
            }
        } else if try tx.allConfirmable() {
            outcome = try tx.finishForward(failed: [])
        } else {
            outcome = try tx.rollForward()
        }
        try tx.runFault(.afterReceipt)
        switch outcome {
        case let .committed(receipt): return .committed(receipt)
        case let .partial(receipt, conflicts, divergences): return .partial(receipt, conflicts: conflicts, divergences: divergences)
        case let .rolledBack(conflicts, divergences): return .conflicts(conflicts, divergences: divergences)
        }
    }

    /// Finishes or undoes the transaction left in `journalDirectory`, from
    /// the state of the disk, in the vault recorded in the journal (never the
    /// one in the current config).
    public static func recover(
        journalDirectory: URL,
        fault: (@Sendable (OKFaultPoint) throws -> Void)? = nil
    ) throws -> OKRecoveryOutcome {
        guard let journal = try Journal.load(from: journalDirectory) else { return .nothing }
        let root = URL(fileURLWithPath: journal.vault.root, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path), journal.vault.matches(root) else {
            return .vaultUnavailable(root: journal.vault.root)
        }
        let tx = OKVaultTransaction(journal: journal, journalDirectory: journalDirectory, fault: fault)
        let outcome: OKVaultTransaction.Outcome
        switch journal.phase {
        case .committed:
            if let conflicts = journal.conflicts, !conflicts.isEmpty {
                return .partial(journal.receipt, conflicts: conflicts, divergences: journal.divergences ?? [])
            }
            return .committed(journal.receipt)
        case .rolledBackWithDivergences:
            return .rolledBack(conflicts: [], divergences: journal.divergences ?? [])
        case .rolledBack:
            outcome = try tx.finishRollback()
        case .rollingForward:
            outcome = try tx.rollForward()
        case .prepared:
            outcome = try tx.allConfirmable() ? tx.finishForward(failed: []) : tx.rollback()
        case .rollingBack:
            outcome = try tx.rollback()
        }
        switch outcome {
        case let .committed(receipt): return .committed(receipt)
        case let .partial(receipt, conflicts, divergences): return .partial(receipt, conflicts: conflicts, divergences: divergences)
        case let .rolledBack(conflicts, divergences): return .rolledBack(conflicts: conflicts, divergences: divergences)
        }
    }

    /// After the app finalized its local state: deletes the staging files
    /// that hold our content or the approved original and were never in a
    /// destination, moves every other one to
    /// `.ok/local/voicetype-preserved/<txid>/`, and deletes the journal.
    /// Returns every file in that folder that holds neither version, so an
    /// attempt after one that failed midway still reports what the earlier
    /// one moved. Does nothing unless the journal is `committed`.
    @discardableResult
    public static func finish(
        journalDirectory: URL,
        fault: (@Sendable (OKFaultPoint) throws -> Void)? = nil
    ) throws -> [OKDivergence] {
        guard let journal = try Journal.load(from: journalDirectory), journal.phase == .committed else { return [] }
        let tx = OKVaultTransaction(journal: journal, journalDirectory: journalDirectory, fault: fault)
        for file in try tx.inventory() {
            guard let hash = try OKVaultTransaction.hash(file.url) else { continue }
            let ours = file.allowed.contains(hash)
            if ours { try tx.runFault(.cleanupBeforeDelete(file.url.lastPathComponent)) }
            if ours, !file.mayBeOpen {
                try FileManager.default.removeItem(at: file.url)
            } else {
                _ = try tx.preserve(file)
            }
        }
        let kept = try tx.preservedDivergences()
        try tx.removeEmptyStaging()
        try tx.removeJournal()
        return kept
    }

    // MARK: - Validation

    /// Relative, `/`-separated, no empty/`.`/`..` component, `.md`/`.yml`,
    /// not under the vault's own `.ok/` or `.git/`, and every existing
    /// ancestor resolving (symlinks followed) inside the vault. An existing
    /// destination must be a regular file, never a symlink.
    static func validate(_ relPath: String, root: URL, canonicalRoot: String) throws {
        let parts = relPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relPath.hasPrefix("/"), !relPath.contains("\\"),
              !relPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              relPath.hasSuffix(".md") || relPath.hasSuffix(".yml"),
              parts.first != ".ok", parts.first != ".git"
        else { throw WriteError.invalidPath(relPath) }

        var url = root
        for (k, part) in parts.enumerated() {
            url.appendPathComponent(part)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { break }
            let isLast = k == parts.count - 1
            if isLast {
                guard info.st_mode & S_IFMT == S_IFREG else { throw WriteError.invalidPath(relPath) }
            }
            let resolved = try realPath(url.path)
            guard resolved.hasPrefix(canonicalRoot + "/"), !resolved.hasPrefix(canonicalRoot + "/.ok/"), resolved != canonicalRoot + "/.ok"
            else { throw WriteError.invalidPath(relPath) }
        }
    }

    static func realPath(_ path: String) throws -> String {
        guard let resolved = Darwin.realpath(path, nil) else { throw OKDurableFile.posixError() }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The destination's ancestors that don't exist yet, shallowest first.
    private static func missingDirectories(of relPath: String, root: URL) -> [String] {
        let parts = relPath.split(separator: "/").dropLast().map(String.init)
        var missing: [String] = []
        for k in parts.indices {
            let dir = parts[...k].joined(separator: "/")
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent(dir).path) { missing.append(dir) }
        }
        return missing
    }

    private static func read(_ url: URL) throws -> Data? {
        try OKVaultTransaction.hash(url) == nil ? nil : Data(contentsOf: url)
    }

    static func conflict(itemID: UUID?, path: String, data: Data?) -> OKConflict {
        OKConflict(
            itemID: itemID, path: path,
            currentContent: data.map { String(decoding: $0, as: UTF8.self) },
            currentHash: data.map(OKPath.contentHash)
        )
    }
}

// MARK: - Journal

extension OKVaultWriter {
    /// The durable intent, in `<meeting dir>/ok-commit/journal.json` (outside
    /// the vault). Staging file names are relative to `staging`.
    struct Journal: Codable, Equatable {
        /// `rolledBack`: the rollback (or a cancellation before any rename)
        /// is over and recorded with its conflicts and divergences; only the
        /// staging cleanup remains, and recovering it never touches the vault.
        enum Phase: String, Codable { case prepared, committed, rollingBack, rollingForward, rolledBack, rolledBackWithDivergences }
        enum Kind: String, Codable { case create, update }

        struct Op: Codable, Equatable {
            /// Position in the `ops` given to `commit`.
            var index: Int
            var kind: Kind
            var path: String
            var itemID: UUID?
            var tmp: String
            var preimage: String?
            var removed: String?
            var copy: String
            var restore: String
            /// The version a `swappedOverForeign` repair put back, recorded
            /// before the repair. Never E nor N.
            var foreignPreimageHash: String?
            /// The inode `tmp` was created with: a `tmp` with another one
            /// came out of the destination.
            var tmpInode: UInt64?
            var newHash: String
            var expectedHash: String?
            var createdDirs: [String]
        }

        struct Dependency: Codable, Equatable {
            var path: String
            var snapshot: String
            var snapshotHash: String
            var restore: String
        }

        var version: Int
        var txid: UUID
        var vault: OKVaultIdentity
        var staging: String
        var receipt: OKCommitReceipt
        var phase: Phase
        var conflicts: [OKConflict]?
        var divergences: [OKDivergence]?
        var ops: [Op]
        var dependencies: [Dependency]

        static func load(from directory: URL) throws -> Journal? {
            let url = directory.appendingPathComponent(MeetingProposalStore.journalFileName)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
        }
    }
}

// MARK: - Transaction

/// One journal being applied, rolled back or completed. Every step
/// reclassifies the ops from the disk before and after acting, so running any
/// of them again after a crash is safe.
final class OKVaultTransaction {
    typealias Journal = OKVaultWriter.Journal

    enum Outcome {
        case committed(OKCommitReceipt)
        case partial(OKCommitReceipt, [OKConflict], [OKDivergence])
        case rolledBack([OKConflict], [OKDivergence])
    }

    /// What the evidence (destination, `tmp`, `pre`, `removed`) says about an op.
    enum State: Equatable {
        // Both kinds.
        case notApplied, identical, foreign, rolledBack, capturedForeign, inconsistent
        // Create.
        case applied, overwrittenAfterPlace, deletedAfterPlace, recreatedAfterRollback
        // Update.
        case missing, verified, swappedOverForeign, revertedByOther, overwrittenAfterSwap, deletedAfterSwap,
             repairedForeign, replayedAfterUndo, inPlace, overwrittenAfterUndo, deletedAfterUndo
    }

    struct Status {
        var state: State
        var dst: String?
        /// Update swapped: where the version taken out of the destination is.
        var artifact: URL?
        var artifactHash: String?
    }

    struct StagingFile {
        var url: URL
        var path: String
        var allowed: Set<String>
        /// The file was in a destination, so someone may still write through
        /// a descriptor they opened there: it's moved, never deleted.
        var mayBeOpen: Bool
    }

    static let foreignReason = "Versão escrita por outro processo durante a gravação, guardada em vez de apagada."

    var journal: Journal
    let journalDirectory: URL
    let root: URL
    let staging: URL
    let fault: (@Sendable (OKFaultPoint) throws -> Void)?
    private let fm = FileManager.default

    init(journal: Journal, journalDirectory: URL, fault: (@Sendable (OKFaultPoint) throws -> Void)?) {
        self.journal = journal
        self.journalDirectory = journalDirectory
        self.root = URL(fileURLWithPath: journal.vault.root, isDirectory: true)
        self.staging = URL(fileURLWithPath: journal.staging, isDirectory: true)
        self.fault = fault
    }

    func runFault(_ point: OKFaultPoint) throws {
        try fault?(point)
    }

    // MARK: Journal file

    func saveJournal() throws {
        try fm.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let tmp = journalDirectory.appendingPathComponent(MeetingProposalStore.journalFileName + ".tmp")
        try OKDurableFile.write(try encoder.encode(journal), to: tmp)
        guard rename(tmp.path, journalDirectory.appendingPathComponent(MeetingProposalStore.journalFileName).path) == 0 else {
            throw OKDurableFile.posixError()
        }
        try OKDurableFile.syncDirectory(journalDirectory)
    }

    func setPhase(_ phase: Journal.Phase) throws {
        guard journal.phase != phase else { return }
        journal.phase = phase
        try saveJournal()
    }

    func removeJournal() throws {
        let url = journalDirectory.appendingPathComponent(MeetingProposalStore.journalFileName)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try? OKDurableFile.syncDirectory(journalDirectory)
        rmdir(journalDirectory.path)
    }

    /// Nothing was renamed yet: records the cancellation as `rolledBack`
    /// before deleting anything, then cleans up. Only a simulated crash is
    /// rethrown; after any other failure the journal is left for `recover`.
    func discard() throws {
        guard fm.fileExists(atPath: journalDirectory.appendingPathComponent(MeetingProposalStore.journalFileName).path) else {
            try? fm.removeItem(at: staging)
            return
        }
        do {
            try markRolledBack(conflicts: [])
            _ = try finishRollback()
        } catch let crash as OKSimulatedCrash {
            throw crash
        } catch {}
    }

    // MARK: Evidence

    static func hash(_ url: URL) throws -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw OKDurableFile.posixError()
        }
        return OKPath.contentHash(try Data(contentsOf: url))
    }

    static func inode(_ url: URL) throws -> UInt64? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw OKDurableFile.posixError()
        }
        return UInt64(info.st_ino)
    }

    func dst(_ op: Journal.Op) -> URL { root.appendingPathComponent(op.path) }
    func current(_ op: Journal.Op) throws -> Data? { try Self.hash(dst(op)) == nil ? nil : Data(contentsOf: dst(op)) }
    func file(_ name: String) -> URL { staging.appendingPathComponent(name) }
    func file(_ name: String?) -> URL? { name.map { staging.appendingPathComponent($0) } }

    func classify(_ op: Journal.Op) throws -> Status {
        let d = try Self.hash(dst(op))
        let t = try Self.hash(file(op.tmp))
        let n = op.newHash
        switch op.kind {
        case .create:
            let r = try file(op.removed).flatMap(Self.hash)
            let state: State
            if t == n, r == nil {
                state = d == nil ? .notApplied : d == n ? .identical : .foreign
            } else if t == nil, r == nil {
                state = d == n ? .applied : d == nil ? .deletedAfterPlace : .overwrittenAfterPlace
            } else if t == nil, let r {
                state = r == n ? (d == nil ? .rolledBack : .recreatedAfterRollback) : .capturedForeign
            } else {
                state = .inconsistent
            }
            return Status(state: state, dst: d)
        case .update:
            let pre = file(op.preimage ?? "pre-\(op.index)")
            let p = try Self.hash(pre)
            let e = op.expectedHash ?? ""
            if t == n, p == nil {
                let state: State = d == e ? .notApplied : d == n ? .identical : d == nil ? .missing : .foreign
                return Status(state: state, dst: d)
            }
            if p == n {
                let state: State
                if d == e { state = .rolledBack }
                else if let d, d == op.foreignPreimageHash { state = .repairedForeign }
                else if d == n { state = journal.phase == .rollingForward ? .inPlace : .replayedAfterUndo }
                else if d == nil { state = .deletedAfterUndo }
                else { state = .overwrittenAfterUndo }
                return Status(state: state, dst: d)
            }
            let artifact: URL
            let a: String
            if let t, t != n, p == nil {
                artifact = file(op.tmp)
                a = t
            } else if let p, t == nil {
                artifact = pre
                a = p
            } else {
                return Status(state: .inconsistent, dst: d)
            }
            let state: State
            if d == n { state = a == e ? .verified : .swappedOverForeign }
            else if d == a { state = .revertedByOther }
            else if d == e { state = .capturedForeign }
            else if d == nil { state = .deletedAfterSwap }
            else { state = .overwrittenAfterSwap }
            return Status(state: state, dst: d, artifact: artifact, artifactHash: a)
        }
    }

    /// The destination holds something written after our content was there
    /// (or our exact bytes, placed by someone else), which undoing would
    /// erase: the transaction must be completed.
    static func isIrreversible(_ state: State) -> Bool {
        switch state {
        case .identical, .capturedForeign, .overwrittenAfterPlace, .recreatedAfterRollback,
             .overwrittenAfterSwap, .overwrittenAfterUndo, .replayedAfterUndo, .inconsistent:
            true
        default:
            false
        }
    }

    func anyIrreversible() throws -> Bool {
        try journal.ops.contains { Self.isIrreversible(try classify($0).state) }
    }

    func allConfirmable() throws -> Bool {
        try journal.ops.allSatisfy { [.applied, .verified, .identical].contains(try classify($0).state) }
    }

    // MARK: Renames

    /// `renamex_np`; `false` when a side is missing (`ENOENT`) or, with
    /// `RENAME_EXCL`, the target exists.
    private func move(_ from: URL, _ to: URL, _ flags: Int32) throws -> Bool {
        if renamex_np(from.path, to.path, UInt32(flags)) == 0 { return true }
        let code = errno
        if code == ENOENT || code == EEXIST { return false }
        throw OKDurableFile.posixError(code)
    }

    private func sync(_ urls: URL...) throws {
        for url in urls { try OKDurableFile.syncDirectory(url.deletingLastPathComponent()) }
    }

    /// Swaps `src` into `dst` and keeps it only if `expected` came out;
    /// otherwise swaps back.
    private func conditionalSwap(_ src: URL, _ dst: URL, expectingOut expected: String) throws {
        guard try move(src, dst, RENAME_SWAP) else { return }
        try sync(dst, src)
        if try Self.hash(src) != expected, try move(src, dst, RENAME_SWAP) {
            try sync(dst, src)
        }
    }

    private func createDirectories(_ op: Journal.Op) throws {
        var url = root
        for part in op.path.split(separator: "/").dropLast() {
            url.appendPathComponent(String(part), isDirectory: true)
            if !fm.fileExists(atPath: url.path) {
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
                try sync(url)
            }
        }
    }

    /// The version taken out of the destination always goes to `pre-<i>`
    /// before it's swapped back or reapplied.
    private func moveArtifactToPre(_ op: Journal.Op) throws {
        guard let preimage = op.preimage, let t = try Self.hash(file(op.tmp)), t != op.newHash else { return }
        if try move(file(op.tmp), file(preimage), RENAME_EXCL) { try OKDurableFile.syncDirectory(staging) }
    }

    // MARK: Apply

    /// The normal path for one op. `false` means conflict.
    func apply(_ op: Journal.Op) throws -> Bool {
        switch op.kind {
        case .create:
            try createDirectories(op)
            guard try move(file(op.tmp), dst(op), RENAME_EXCL) else { return false }
            try sync(dst(op), file(op.tmp))
            return true
        case .update:
            guard try move(file(op.tmp), dst(op), RENAME_SWAP) else { return false }
            try sync(dst(op), file(op.tmp))
            try runFault(.afterSwap(op.index))
            try moveArtifactToPre(op)
            if try classify(op).state == .swappedOverForeign {
                try repair(op)
                return false
            }
            return true
        }
    }

    /// `swappedOverForeign`: someone replaced E by A before our swap. A goes
    /// back to the destination (fph recorded first), and N must come out.
    private func repair(_ op: Journal.Op) throws {
        guard let k = journal.ops.firstIndex(where: { $0.index == op.index }),
              let a = try classify(op).artifactHash, let preimage = op.preimage else { return }
        journal.ops[k].foreignPreimageHash = a
        try saveJournal()
        try moveArtifactToPre(op)
        try conditionalSwap(file(preimage), dst(op), expectingOut: op.newHash)
    }

    // MARK: Rollback

    func rollback() throws -> Outcome {
        try setPhase(.rollingBack)
        for op in journal.ops.reversed() {
            if try anyIrreversible() { return try rollForward() }
            let status = try classify(op)
            try runFault(.rollbackBeforeUndo(op.index))
            switch (op.kind, status.state) {
            case (.create, .applied):
                if let removed = file(op.removed), try move(dst(op), removed, RENAME_EXCL) {
                    try sync(dst(op), removed)
                }
                try runFault(.rollbackAfterUndo(op.index))
            case (.update, .verified):
                try moveArtifactToPre(op)
                if let pre = file(op.preimage), try move(pre, dst(op), RENAME_SWAP) {
                    try sync(dst(op), pre)
                }
                try runFault(.rollbackAfterUndo(op.index))
            case (.update, .swappedOverForeign):
                try repair(op)
            default:
                break
            }
            try runFault(.afterRollback(op.index))
        }
        if try anyIrreversible() { return try rollForward() }

        // Whatever no longer matches its state before the transaction.
        var conflicts: [OKConflict] = []
        for op in journal.ops {
            let current = try current(op)
            if current.map(OKPath.contentHash) != (op.kind == .update ? op.expectedHash : nil) {
                conflicts.append(OKVaultWriter.conflict(itemID: op.itemID, path: op.path, data: current))
            }
        }
        try markRolledBack(conflicts: conflicts)
        return try finishRollback()
    }

    /// Records the end of the rollback, with what it reports, before the
    /// cleanup deletes the staging files the classification reads.
    private func markRolledBack(conflicts: [OKConflict]) throws {
        let divergences = try foreignStagingFiles()
        journal.phase = .rolledBack
        journal.conflicts = conflicts.isEmpty ? nil : conflicts
        journal.divergences = divergences.isEmpty ? nil : divergences
        try saveJournal()
    }

    /// The cleanup of a `rolledBack` journal, idempotent and never touching
    /// a destination: removes the folders the transaction created that are
    /// empty, deletes the staging files that are ours or the approved
    /// original and were never in a destination, and moves the ones that
    /// were (`mayBeOpen`) to `.ok/local/voicetype-preserved/<txid>/`. Every
    /// attempt re-reads the staging: a file that changed since the rollback
    /// (written through a descriptor someone kept) is an outside version,
    /// recorded in the journal before going on and never deleted; so is a
    /// moved file that no longer holds what it held when it was read. The
    /// staging folder is only removed empty; with an outside version left,
    /// the journal becomes `rolledBackWithDivergences`.
    func finishRollback() throws -> Outcome {
        for dir in Set(journal.ops.flatMap(\.createdDirs)).sorted(by: { $0.count > $1.count }) {
            rmdir(root.appendingPathComponent(dir).path)
        }
        var divergences = journal.divergences ?? []
        for file in try inventory() {
            guard let hash = try Self.hash(file.url) else { continue }
            if file.allowed.contains(hash) {
                try runFault(.cleanupBeforeDelete(file.url.lastPathComponent))
                if !file.mayBeOpen {
                    try fm.removeItem(at: file.url)
                } else if let divergence = try preserve(file) {
                    divergences.append(divergence)
                    journal.divergences = divergences
                    try saveJournal()
                }
            } else if !divergences.contains(where: { $0.preservedCopy == file.url.path }) {
                divergences.append(OKDivergence(path: file.path, preservedCopy: file.url.path, reason: Self.foreignReason))
                journal.divergences = divergences
                try saveJournal()
            }
        }
        if divergences.isEmpty {
            try removeEmptyStaging()
            try removeJournal()
        } else {
            try setPhase(.rolledBackWithDivergences)
        }
        return .rolledBack(journal.conflicts ?? [], divergences)
    }

    /// `rmdir`, never a recursive delete: a file that showed up in the
    /// staging after the inventory makes it fail, and the journal stays for
    /// the next attempt.
    func removeEmptyStaging() throws {
        guard rmdir(staging.path) == 0 || errno == ENOENT else { throw OKDurableFile.posixError() }
    }

    // MARK: Completion

    func rollForward() throws -> Outcome {
        try setPhase(.rollingForward)
        var failed: [String] = []
        for op in journal.ops {
            do {
                try runFault(.forwardBeforeApply(op.index))
                try forward(op)
            } catch let crash as OKSimulatedCrash {
                throw crash
            } catch {
                failed.append(op.path)
            }
        }
        return try finishForward(failed: failed)
    }

    /// Brings one op to a final state, reclassifying after each step.
    private func forward(_ op: Journal.Op) throws {
        for _ in 0..<4 {
            let status = try classify(op)
            switch (op.kind, status.state) {
            case (.create, .notApplied):
                try createDirectories(op)
                guard try move(file(op.tmp), dst(op), RENAME_EXCL) else { continue }
                try sync(dst(op), file(op.tmp))
            case (.create, .rolledBack), (.create, .capturedForeign):
                // rolledBack implies no destination; a captured version with
                // something new in its place stays in the staging.
                guard status.dst == nil else { return }
                guard let removed = file(op.removed) else { return }
                try createDirectories(op)
                guard try move(removed, dst(op), RENAME_EXCL) else { continue }
                try sync(dst(op), removed)
            case (_, .deletedAfterPlace), (_, .missing), (_, .deletedAfterSwap), (_, .deletedAfterUndo), (_, .inconsistent):
                guard status.dst == nil else { return }
                try restore(op)
            case (.update, .notApplied):
                guard try move(file(op.tmp), dst(op), RENAME_SWAP) else { continue }
                try sync(dst(op), file(op.tmp))
                try moveArtifactToPre(op)
            case (.update, .rolledBack):
                guard let pre = file(op.preimage), try move(pre, dst(op), RENAME_SWAP) else { continue }
                try sync(dst(op), pre)
            case (.update, .swappedOverForeign):
                try repair(op)
            case (.update, .capturedForeign):
                // The rollback swapped out a newer outside version: it goes back, E stays in pre.
                guard let preimage = op.preimage else { return }
                try moveArtifactToPre(op)
                try conditionalSwap(file(preimage), dst(op), expectingOut: op.expectedHash ?? "")
            default:
                return
            }
        }
    }

    /// Puts our approved content back from `copy-<i>` through the exclusive
    /// `restore-<i>`, never through `tmp`/`pre`, which may hold the only copy
    /// of an outside version.
    private func restore(_ op: Journal.Op) throws {
        try runFault(.forwardBeforeRestore(op.index))
        try restoreFile(from: file(op.copy), through: file(op.restore), to: dst(op), hash: op.newHash, op: op)
    }

    private func restoreDependency(_ k: Int) throws {
        let dep = journal.dependencies[k]
        try runFault(.forwardBeforeRestoreDependency(k))
        try restoreFile(from: file(dep.snapshot), through: file(dep.restore), to: root.appendingPathComponent(dep.path), hash: dep.snapshotHash, op: nil)
    }

    private func restoreFile(from source: URL, through scratch: URL, to target: URL, hash: String, op: Journal.Op?) throws {
        let data = try Data(contentsOf: source)
        guard OKPath.contentHash(data) == hash else { throw OKDurableFile.posixError(EIO) }
        try OKDurableFile.write(data, to: scratch)
        guard try Self.hash(scratch) == hash else { throw OKDurableFile.posixError(EIO) }
        if let op {
            try createDirectories(op)
        } else {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        if try move(scratch, target, RENAME_EXCL) { try sync(target, scratch) }
    }

    /// A state the completion leaves as it is: our content or a later
    /// version in place, or an outside version reported as conflict. Not
    /// applied, undone, missing, inconsistent or still to repair isn't.
    static func isFinal(_ status: Status, kind: Journal.Kind) -> Bool {
        switch status.state {
        case .applied, .identical, .overwrittenAfterPlace, .recreatedAfterRollback, .verified, .inPlace,
             .overwrittenAfterSwap, .overwrittenAfterUndo, .replayedAfterUndo, .foreign, .revertedByOther, .repairedForeign:
            status.dst != nil
        case .capturedForeign:
            kind == .create && status.dst != nil
        default:
            false
        }
    }

    /// Final check before any `committed`/`partial`. Brings every op to a
    /// final state and restores missing dependencies, in passes until one
    /// changes nothing (a step can disturb a file already checked), then
    /// revalidates everything without acting. An op not final or a
    /// dependency missing leaves the journal in `rollingForward` and throws
    /// `incomplete`. `failed`: ops whose step already failed this round,
    /// which aren't retried.
    func finishForward(failed initial: [String]) throws -> Outcome {
        var failed = initial
        for _ in 0..<3 {
            var acted = false
            for op in journal.ops where !failed.contains(op.path) {
                if Self.isFinal(try classify(op), kind: op.kind) { continue }
                acted = true
                try setPhase(.rollingForward)
                do {
                    try forward(op)
                } catch let crash as OKSimulatedCrash {
                    throw crash
                } catch {
                    failed.append(op.path)
                }
            }
            for (k, dep) in journal.dependencies.enumerated() {
                if try Self.hash(root.appendingPathComponent(dep.path)) != nil { continue }
                acted = true
                try setPhase(.rollingForward)
                do {
                    try restoreDependency(k)
                } catch let crash as OKSimulatedCrash {
                    throw crash
                } catch {}
            }
            if !acted { break }
        }

        var absent: [String] = []
        for op in journal.ops {
            if try failed.contains(op.path) || !Self.isFinal(classify(op), kind: op.kind) { absent.append(op.path) }
        }
        for dep in journal.dependencies {
            if try Self.hash(root.appendingPathComponent(dep.path)) == nil { absent.append(dep.path) }
        }
        guard absent.isEmpty else {
            try setPhase(.rollingForward)
            throw OKVaultWriter.WriteError.incomplete(absent)
        }

        var conflicts: [OKConflict] = []
        var written: [String] = []
        for op in journal.ops {
            let status = try classify(op)
            let isConflict: Bool
            switch status.state {
            case .foreign, .revertedByOther, .repairedForeign: isConflict = true
            case .overwrittenAfterSwap: isConflict = status.artifactHash != op.expectedHash
            default: isConflict = false
            }
            if isConflict {
                conflicts.append(OKVaultWriter.conflict(itemID: op.itemID, path: op.path, data: try current(op)))
            } else {
                written.append(op.path)
            }
        }
        let divergences = try foreignStagingFiles()
        journal.receipt.written = written
        journal.phase = .committed
        journal.conflicts = conflicts.isEmpty ? nil : conflicts
        journal.divergences = divergences.isEmpty ? nil : divergences
        try saveJournal()
        return conflicts.isEmpty ? .committed(journal.receipt) : .partial(journal.receipt, conflicts, divergences)
    }

    // MARK: Staging cleanup

    /// Every file in the staging folder, with the hashes that make it safe
    /// to delete: N or E of its op, the snapshot hash of a dependency, none
    /// for a file the journal doesn't know. A destination's inode only ever
    /// comes out into `pre`, `removed` or (swapped, not yet moved to `pre`)
    /// `tmp`; `copy`, `restore` and the dependency files are always ours.
    func inventory() throws -> [StagingFile] {
        var files: [StagingFile] = []
        var known = Set<String>()
        for op in journal.ops {
            let allowed = Set([op.newHash] + (op.expectedHash.map { [$0] } ?? []))
            let swappedTmp = try Self.inode(file(op.tmp)).map { $0 != op.tmpInode } ?? false
            let names: [(String?, Bool)] = [(op.tmp, swappedTmp), (op.preimage, true), (op.removed, true), (op.copy, false), (op.restore, false)]
            for case let (name?, mayBeOpen) in names {
                known.insert(name)
                files.append(StagingFile(url: file(name), path: op.path, allowed: allowed, mayBeOpen: mayBeOpen))
            }
        }
        for dep in journal.dependencies {
            for name in [dep.snapshot, dep.restore] {
                known.insert(name)
                files.append(StagingFile(url: file(name), path: dep.path, allowed: [dep.snapshotHash], mayBeOpen: false))
            }
        }
        let names = (try? fm.contentsOfDirectory(atPath: staging.path)) ?? []
        for name in names.sorted() where !known.contains(name) {
            files.append(StagingFile(url: file(name), path: name, allowed: [], mayBeOpen: false))
        }
        return files
    }

    /// Moves a staging file to `.ok/local/voicetype-preserved/<txid>/`, on
    /// disk before returning; a divergence when what was moved is neither
    /// ours nor the approved original.
    func preserve(_ file: StagingFile) throws -> OKDivergence? {
        let preserved = preservedDirectory
        try fm.createDirectory(at: preserved, withIntermediateDirectories: true)
        let target = preserved.appendingPathComponent(file.url.lastPathComponent)
        guard try move(file.url, target, RENAME_EXCL) else { throw OKDurableFile.posixError(EEXIST) }
        try sync(target, file.url)
        guard let hash = try Self.hash(target), !file.allowed.contains(hash) else { return nil }
        return OKDivergence(path: file.path, preservedCopy: target.path, reason: Self.foreignReason)
    }

    var preservedDirectory: URL {
        root.appendingPathComponent(".ok/local/voicetype-preserved/\(journal.txid.uuidString)", isDirectory: true)
    }

    /// The files this transaction moved to `preservedDirectory`, in this
    /// attempt or an earlier one, that hold neither ours nor the approved
    /// original; a name the journal doesn't know is always one.
    func preservedDivergences() throws -> [OKDivergence] {
        let known = Dictionary(try inventory().map { ($0.url.lastPathComponent, $0) }) { first, _ in first }
        let names = (try? fm.contentsOfDirectory(atPath: preservedDirectory.path)) ?? []
        return try names.sorted().compactMap { name in
            let copy = preservedDirectory.appendingPathComponent(name)
            guard let hash = try Self.hash(copy), known[name]?.allowed.contains(hash) != true else { return nil }
            return OKDivergence(path: known[name]?.path ?? name, preservedCopy: copy.path, reason: Self.foreignReason)
        }
    }

    /// The staging files holding an outside version (neither ours nor the
    /// approved original), which are never deleted.
    private func foreignStagingFiles() throws -> [OKDivergence] {
        try inventory().compactMap { file in
            guard let hash = try Self.hash(file.url), !file.allowed.contains(hash) else { return nil }
            return OKDivergence(path: file.path, preservedCopy: file.url.path, reason: Self.foreignReason)
        }
    }
}
