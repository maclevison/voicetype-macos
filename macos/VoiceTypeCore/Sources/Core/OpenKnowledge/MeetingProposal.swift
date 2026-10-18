import Foundation

/// What a processed meeting proposes for the OpenKnowledge vault, waiting in
/// the meeting's directory (`ok-proposal.json`) until the user approves it.
public struct MeetingProposal: Codable, Equatable, Sendable {
    public static let fileName = "ok-proposal.json"

    public var version = 1
    /// New on every `build`/`rebuild`; `redistill`, `repath` and a partial
    /// completion keep it. The window only saves over its own generation.
    public var generation: UUID
    /// The record and transcript are already in the vault (partial completion).
    public var recordWritten: Bool
    public var meetingID: UUID
    public var note: MeetingNote
    /// The vault it was prepared for; nil when that vault was invalid.
    public var vault: OKVaultIdentity?
    public var summaryFailure: String?
    public var distillationError: String?
    public var suggestedProject: String?
    public var project: String?
    /// The paths the distillation and the preview used. Persisted, never
    /// recomputed behind the user's back.
    public var paths: OKMeetingPaths?
    /// Paths of an earlier approval in this vault: the project is locked.
    public var fixedPaths: OKMeetingPaths?
    public var existingRecordHash: String?
    public var existingTranscriptHash: String?
    /// The record a conflict found in the vault (`existingRecordHash` is its
    /// hash): what the record's diff is shown against until it's replaced.
    public var existingRecordContent: String?
    public var catalogFingerprint: String?
    public var distilledAt: Date?
    public var items: [OKProposedItem]

    public init(
        generation: UUID = UUID(), recordWritten: Bool = false, meetingID: UUID, note: MeetingNote,
        vault: OKVaultIdentity? = nil, summaryFailure: String? = nil, distillationError: String? = nil,
        suggestedProject: String? = nil, project: String? = nil, paths: OKMeetingPaths? = nil,
        fixedPaths: OKMeetingPaths? = nil, existingRecordHash: String? = nil, existingTranscriptHash: String? = nil,
        existingRecordContent: String? = nil, catalogFingerprint: String? = nil, distilledAt: Date? = nil, items: [OKProposedItem] = []
    ) {
        self.generation = generation
        self.recordWritten = recordWritten
        self.meetingID = meetingID
        self.note = note
        self.vault = vault
        self.summaryFailure = summaryFailure
        self.distillationError = distillationError
        self.suggestedProject = suggestedProject
        self.project = project
        self.paths = paths
        self.fixedPaths = fixedPaths
        self.existingRecordHash = existingRecordHash
        self.existingTranscriptHash = existingTranscriptHash
        self.existingRecordContent = existingRecordContent
        self.catalogFingerprint = catalogFingerprint
        self.distilledAt = distilledAt
        self.items = items
    }
}

/// Reads and writes a meeting's proposal. Every read-check-write of
/// `ok-proposal.json`, `ok-progress.json`, the journal and `pipeline.json`
/// in OpenKnowledge mode runs inside `withLock`, and nothing async runs
/// while it's held.
public enum MeetingProposalStore {
    public static let progressFileName = "ok-progress.json"
    public static let journalFolder = "ok-commit"
    public static let journalFileName = "journal.json"

    public enum StoreError: Error, Equatable {
        /// The proposal on disk is of another generation, or gone.
        case generationChanged
        /// A vault write left a journal for this meeting.
        case meetingBusy
    }

    public enum ReplaceOutcome: Equatable, Sendable {
        case replaced, meetingBusy, approvedMeanwhile
    }

    private static let lock = NSRecursiveLock()

    public static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public static func load(_ dir: URL) -> MeetingProposal? {
        withLock { try? decode(Data(contentsOf: proposalURL(dir))) }
    }

    /// The window's path: writes `p` only over a proposal of the same generation.
    public static func save(_ p: MeetingProposal, in dir: URL) throws {
        try withLock {
            guard load(dir)?.generation == p.generation else { throw StoreError.generationChanged }
            try write(p, in: dir)
        }
    }

    /// The processor's path (first run and reprocess). Refuses, writing
    /// nothing, while a journal exists or when an approval finished since
    /// `state` was read (`okVault`/`okRecordPath` changed on disk). Otherwise
    /// writes `p`, drops the window's progress and applies `update` to the
    /// `pipeline.json` read back from disk (`state` only when there's none),
    /// so paths the finalizer saved stay.
    public static func replaceFromReprocessing(
        _ p: MeetingProposal, in dir: URL, builtFrom state: MeetingPipelineState,
        update: (inout MeetingPipelineState) -> Void
    ) throws -> ReplaceOutcome {
        try withLock {
            if hasJournal(dir) { return .meetingBusy }
            var current = loadState(dir) ?? state
            if current.okVault != state.okVault || current.okRecordPath != state.okRecordPath { return .approvedMeanwhile }
            try write(p, in: dir)
            try removeIfPresent(dir.appendingPathComponent(progressFileName))
            update(&current)
            try JSONEncoder().encode(current).write(to: dir.appendingPathComponent(MeetingPipelineState.stateFileName), options: .atomic)
            return .replaced
        }
    }

    /// The window replacing its own proposal (preparing it for another
    /// vault): only over generation `old` and with no journal. Sessions bound
    /// to `old` are refused by `save` afterwards.
    public static func replace(_ new: MeetingProposal, in dir: URL, expecting old: UUID) throws {
        try withLock {
            if hasJournal(dir) { throw StoreError.meetingBusy }
            guard load(dir)?.generation == old else { throw StoreError.generationChanged }
            try write(new, in: dir)
            try removeIfPresent(dir.appendingPathComponent(progressFileName))
        }
    }

    /// Deletes the proposal and the window's progress; with `generation`,
    /// only when the proposal on disk is of that generation.
    public static func remove(_ dir: URL, generation: UUID? = nil) {
        withLock {
            if let generation, load(dir)?.generation != generation { return }
            try? removeIfPresent(proposalURL(dir))
            try? removeIfPresent(dir.appendingPathComponent(progressFileName))
        }
    }

    public static func hasJournal(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(journalFolder).appendingPathComponent(journalFileName).path)
    }

    // MARK: - Encoding

    static func encode(_ p: MeetingProposal) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(p)
    }

    static func decode(_ data: Data) throws -> MeetingProposal {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingProposal.self, from: data)
    }

    private static func proposalURL(_ dir: URL) -> URL {
        dir.appendingPathComponent(MeetingProposal.fileName)
    }

    private static func write(_ p: MeetingProposal, in dir: URL) throws {
        try encode(p).write(to: proposalURL(dir), options: .atomic)
    }

    private static func loadState(_ dir: URL) -> MeetingPipelineState? {
        try? JSONDecoder().decode(MeetingPipelineState.self, from: Data(contentsOf: dir.appendingPathComponent(MeetingPipelineState.stateFileName)))
    }

    private static func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {}
    }
}

/// A meeting waiting for approval, as the menu lists it.
public struct PendingMeeting: Equatable, Sendable, Identifiable {
    /// The meeting directory's name.
    public var id: String
    public var directory: URL
    public var title: String
    public var startedAt: Date
    public var generation: UUID

    public init(id: String, directory: URL, title: String, startedAt: Date, generation: UUID) {
        self.id = id
        self.directory = directory
        self.title = title
        self.startedAt = startedAt
        self.generation = generation
    }
}

public enum PendingMeetings {
    /// Meeting directories under `base` with a readable proposal, most recent first.
    public static func scan(base: URL, fileManager: FileManager = .default) -> [PendingMeeting] {
        guard let dirs = try? fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir -> PendingMeeting? in
            guard let p = MeetingProposalStore.load(dir) else { return nil }
            return PendingMeeting(id: dir.lastPathComponent, directory: dir, title: p.note.summary.title,
                                  startedAt: p.note.startedAt, generation: p.generation)
        }
        .sorted { ($0.startedAt, $0.id) > ($1.startedAt, $1.id) }
    }
}

/// Prepares a meeting's proposal: suggested project, record paths and the
/// distilled knowledge. The record is always approvable: any failure of the
/// model or the vault lands in `distillationError` with no items.
public struct OKProposalBuilder: Sendable {
    enum BuildError: LocalizedError {
        case assistantUnavailable
        case invalidVault(String)

        var errorDescription: String? {
            switch self {
            case .assistantUnavailable: "Claude CLI não encontrado"
            case .invalidVault(let path): "Vault OpenKnowledge inválido (sem .ok/): \(path)"
            }
        }
    }

    let assistant: (any OKAssistant)?
    let user: String
    let timeZone: TimeZone

    public init(assistant: (any OKAssistant)?, user: String, timeZone: TimeZone = .current) {
        self.assistant = assistant
        self.user = user
        self.timeZone = timeZone
    }

    /// A new proposal (new generation). A meeting already approved into this
    /// vault keeps its paths and project, with no suggestion call.
    public func build(note: MeetingNote, summaryFailure: String?, state: MeetingPipelineState, vault: URL, now: Date) async -> MeetingProposal {
        var p = MeetingProposal(meetingID: state.noteID, note: note, vault: try? OKVaultIdentity.of(vault), summaryFailure: summaryFailure)
        guard p.vault != nil else {
            p.distillationError = BuildError.invalidVault(vault.path).errorDescription
            return p
        }
        if let record = state.okRecordPath, state.okVault?.matches(vault) == true {
            let fixed = OKMeetingPaths(record: record, transcript: state.okTranscriptPath ?? Self.transcriptPath(of: record))
            let project = state.okProject ?? String(record.prefix { $0 != "/" })
            p.fixedPaths = fixed
            p.paths = fixed
            p.project = project
            p.suggestedProject = project
            p.existingRecordHash = Self.hash(fixed.record, in: vault)
            p.existingTranscriptHash = Self.hash(fixed.transcript, in: vault)
            guard summaryFailure == nil else { return p }
            await distillRecordingError(&p, project: project, vault: vault, now: now)
            return p
        }
        guard summaryFailure == nil else { return p }
        do {
            guard let assistant else { throw BuildError.assistantUnavailable }
            let projects = try OKVaultCatalog.projects(in: vault)
            p.suggestedProject = try await assistant.suggestProject(summary: note.summary, projects: projects)
        } catch {
            p.distillationError = Self.message(error)
            return p
        }
        guard let project = p.suggestedProject else { return p }
        p.project = project
        await distillRecordingError(&p, project: project, vault: vault, now: now)
        return p
    }

    /// Distills again for `project` (same generation): recomputes and
    /// persists `paths` unless they are fixed. Throws on any failure.
    public func redistill(_ p: MeetingProposal, project: String, vault: URL, now: Date) async throws -> MeetingProposal {
        guard OKVault.isProjectRoot(vault) else { throw BuildError.invalidVault(vault.path) }
        var q = p
        q.project = project
        try await distill(&q, project: project, vault: vault, now: now)
        q.distillationError = nil
        return q
    }

    /// Moves the proposal to `project` without the model: new paths there
    /// (the project may not exist yet), no items. Never called with `fixedPaths`.
    public static func repath(_ p: MeetingProposal, project: String, vault: URL, timeZone: TimeZone = .current) -> MeetingProposal {
        var q = p
        q.project = project
        q.paths = OKMeetingPaths.available(project: project, startedAt: p.note.startedAt, title: p.note.summary.title,
                                           id: p.note.id, vault: vault, timeZone: timeZone)
        q.items = []
        q.distilledAt = nil
        q.catalogFingerprint = nil
        return q
    }

    /// A fresh proposal for the current vault (new generation), keeping the
    /// meeting and its summary failure: moving a pending meeting to another
    /// vault means reviewing it from scratch.
    public func rebuild(_ p: MeetingProposal, state: MeetingPipelineState, vault: URL, now: Date) async -> MeetingProposal {
        await build(note: p.note, summaryFailure: p.summaryFailure, state: state, vault: vault, now: now)
    }

    /// Distilled items more than 24 h old or made against another docs
    /// catalog. A record-only proposal is never stale.
    public static func isStale(_ p: MeetingProposal, currentFingerprint: String, now: Date) -> Bool {
        guard let distilledAt = p.distilledAt, !p.items.isEmpty else { return false }
        return now.timeIntervalSince(distilledAt) > 24 * 3600 || p.catalogFingerprint != currentFingerprint
    }

    // MARK: - Distillation

    private func distillRecordingError(_ p: inout MeetingProposal, project: String, vault: URL, now: Date) async {
        do {
            try await distill(&p, project: project, vault: vault, now: now)
        } catch {
            p.items = []
            p.distillationError = Self.message(error)
        }
    }

    /// Fixes `paths` once (before the model runs, so a failure still leaves
    /// the record approvable), then plans and writes the docs.
    private func distill(_ p: inout MeetingProposal, project: String, vault: URL, now: Date) async throws {
        let note = p.note
        let paths = p.fixedPaths ?? OKMeetingPaths.available(project: project, startedAt: note.startedAt, title: note.summary.title,
                                                             id: note.id, vault: vault, timeZone: timeZone)
        p.paths = paths
        guard let assistant else { throw BuildError.assistantUnavailable }
        let docs = try OKVaultCatalog.docs(project: project, in: vault)
        let transcript = note.transcript ?? ""
        let plan = try await assistant.planDistillation(summary: note.summary, transcript: transcript, project: project, docs: docs)
        var templates: [OKKnowledgeType: String] = [:]
        var current: [String: String] = [:]
        for item in plan {
            switch item.action {
            case .new where templates[item.type] == nil:
                templates[item.type] = try? OKTemplate.load(item.type, vault: vault, date: now, user: user, timeZone: timeZone)
            case .update:
                current[item.path] = try? String(contentsOf: vault.appendingPathComponent(item.path), encoding: .utf8)
            default:
                break
            }
        }
        p.items = try await assistant.writeDistillation(
            plan, summary: note.summary, transcript: transcript, project: project, recordPath: paths.record,
            meetingTitle: note.summary.title, meetingDate: note.startedAt, templates: templates, current: current
        )
        p.catalogFingerprint = OKVaultCatalog.fingerprint(docs)
        p.distilledAt = now
    }

    // MARK: - Helpers

    private static func transcriptPath(of record: String) -> String {
        let folder = (record as NSString).deletingLastPathComponent
        return "\(folder)/\(OKMeetingPaths.transcriptsFolder)/\((record as NSString).lastPathComponent)"
    }

    private static func hash(_ relPath: String, in vault: URL) -> String? {
        (try? Data(contentsOf: vault.appendingPathComponent(relPath))).map(OKPath.contentHash)
    }

    static func message(_ error: any Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return "Falha na destilação: \(error)"
    }
}
