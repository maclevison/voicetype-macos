import Foundation

/// A project the user creates in the approval window. It's written to the
/// vault in the same transaction as the meeting.
public struct OKNewProject: Codable, Equatable, Sendable {
    public var slug: String
    public var description: String

    public init(slug: String, description: String) {
        self.slug = slug
        self.description = description
    }
}

/// What the user decided for a distilled item. An approval is a stamp of
/// what they saw: the hash of the approved Markdown and the `baseHash` of the
/// version the diff was shown against. An edit, a redistillation or a
/// conflict that changes either one voids it, with no explicit cleanup.
public enum OKItemDecision: Codable, Equatable, Sendable {
    case approved(contentHash: String, baseHash: String?)
    case skipped
}

/// The window's progress on one proposal (`ok-progress.json`), so closing
/// the window midway loses nothing.
public struct OKApprovalProgress: Codable, Equatable, Sendable {
    public static let fileName = MeetingProposalStore.progressFileName

    /// The proposal generation it belongs to; any other is ignored.
    public var generation: UUID
    public var project: String?
    public var newProject: OKNewProject?
    public var stepIndex: Int
    /// Stamp of the approved record: its Markdown bound to the record and
    /// transcript versions it replaces (`OKApprovalSession.recordStamp`).
    public var recordApproval: String?
    public var recordEdit: String?
    public var decisions: [UUID: OKItemDecision]
    public var edits: [UUID: String]

    public var hasEdits: Bool { recordEdit != nil || !edits.isEmpty }

    public init(
        generation: UUID, project: String? = nil, newProject: OKNewProject? = nil, stepIndex: Int = 0,
        recordApproval: String? = nil, recordEdit: String? = nil,
        decisions: [UUID: OKItemDecision] = [:], edits: [UUID: String] = [:]
    ) {
        self.generation = generation
        self.project = project
        self.newProject = newProject
        self.stepIndex = stepIndex
        self.recordApproval = recordApproval
        self.recordEdit = recordEdit
        self.decisions = decisions
        self.edits = edits
    }

    public static func load(_ dir: URL) -> OKApprovalProgress? {
        MeetingProposalStore.withLock {
            try? JSONDecoder().decode(OKApprovalProgress.self, from: Data(contentsOf: dir.appendingPathComponent(fileName)))
        }
    }

    /// Writes only while the proposal on disk is of `generation`; otherwise
    /// throws `StoreError.generationChanged` and writes nothing.
    public func save(in dir: URL) throws {
        try MeetingProposalStore.withLock {
            guard MeetingProposalStore.load(dir)?.generation == generation else {
                throw MeetingProposalStore.StoreError.generationChanged
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
        }
    }
}

/// The approval window's state: project, record and one step per distilled
/// item, the user's edits and decisions, and the vault operations they add
/// up to. Pure value type; the caller persists `proposal` and `progress`.
public struct OKApprovalSession: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case project, record, item(UUID)
    }

    public enum ProjectError: Error, Equatable {
        case invalidSlug, alreadyExists, emptyDescription, projectLocked
    }

    public enum CommitError: Error, Equatable, LocalizedError {
        case vaultMismatch, noPaths, notReady
        /// The final Markdown for this vault path fails `OKFrontmatter.isValidDocument`.
        case invalidFrontmatter(String)

        public var errorDescription: String? {
            guard case let .invalidFrontmatter(path) = self else { return nil }
            return "O frontmatter de \(path) não é YAML válido ou não tem title, description e type como texto. Corrija no Editor antes de gravar."
        }
    }

    public private(set) var proposal: MeetingProposal
    public private(set) var progress: OKApprovalProgress
    /// The record's date and the approval stamps use it.
    public let timeZone: TimeZone

    /// Progress of another generation is ignored: nothing of an earlier
    /// proposal comes back.
    public init(proposal: MeetingProposal, progress: OKApprovalProgress?, timeZone: TimeZone = .current) {
        self.proposal = proposal
        self.timeZone = timeZone
        if let progress, progress.generation == proposal.generation {
            self.progress = progress
        } else {
            self.progress = OKApprovalProgress(generation: proposal.generation, project: proposal.project ?? proposal.suggestedProject)
        }
    }

    public var generation: UUID { proposal.generation }
    /// Persisted with the proposal, never recomputed implicitly.
    public var paths: OKMeetingPaths? { proposal.paths }

    /// With `recordWritten` the record is already in the vault: no record step.
    public var steps: [Step] {
        (proposal.recordWritten ? [Step.project] : [.project, .record]) + proposal.items.map { .item($0.id) }
    }

    /// Past the last step it stays on the last one (`isFinished`).
    public var current: Step {
        let all = steps
        return all[min(max(progress.stepIndex, 0), all.count - 1)]
    }

    /// Every step was answered once; `back()` returns to the last one.
    public var isFinished: Bool { progress.stepIndex >= steps.count }

    public var chosenProject: String? { progress.project }
    public var projectLocked: Bool { proposal.fixedPaths != nil }
    public var needsRedistill: Bool { chosenProject != proposal.project }

    public var recordApproved: Bool {
        proposal.recordWritten || progress.recordApproval == recordStamp()
    }

    /// The record's approval stamp: the hash of its Markdown shown now and of
    /// the versions in the vault it replaces, so a new conflict on the record
    /// or the transcript voids the approval even with the same Markdown.
    public func recordStamp() -> String {
        Self.hash([Self.hash(markdown(for: .record)), proposal.existingRecordHash ?? "-", proposal.existingTranscriptHash ?? "-"]
            .joined(separator: "\n"))
    }

    public func isApproved(_ id: UUID) -> Bool {
        guard case let .approved(content, base) = progress.decisions[id], let item = item(id) else { return false }
        return content == Self.hash(markdown(for: .item(id))) && base == item.baseHash
    }

    public var hasApprovedItems: Bool { proposal.items.contains { isApproved($0.id) } }

    /// The record approved, every item approved or skipped, and the proposal
    /// prepared for the chosen project.
    public var canCommit: Bool {
        chosenProject != nil && !needsRedistill && recordApproved && proposal.items.allSatisfy { isDecided($0.id) }
    }

    // MARK: - Project

    public mutating func chooseProject(_ slug: String) throws {
        guard !projectLocked || slug == proposal.project else { throw ProjectError.projectLocked }
        progress.project = slug
        progress.newProject = nil
    }

    public mutating func chooseNewProject(slug: String, description: String, existing: [OKProject]) throws {
        guard !projectLocked else { throw ProjectError.projectLocked }
        guard OKSlug.isValid(slug) else { throw ProjectError.invalidSlug }
        guard !existing.contains(where: { $0.slug == slug }) else { throw ProjectError.alreadyExists }
        let about = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !about.isEmpty else { throw ProjectError.emptyDescription }
        progress.project = slug
        progress.newProject = OKNewProject(slug: slug, description: about)
    }

    // MARK: - Navigation

    /// `.project` advances only with a project chosen; `.record` and items
    /// stamp the Markdown shown now.
    public mutating func approve() {
        switch current {
        case .project:
            guard chosenProject != nil else { return }
        case .record:
            progress.recordApproval = recordStamp()
        case let .item(id):
            progress.decisions[id] = .approved(contentHash: Self.hash(markdown(for: .item(id))), baseHash: item(id)?.baseHash)
        }
        advance()
    }

    /// Only items can be skipped.
    public mutating func skip() {
        guard case let .item(id) = current else { return }
        progress.decisions[id] = .skipped
        advance()
    }

    public mutating func back() {
        progress.stepIndex = max(0, min(progress.stepIndex, steps.count) - 1)
    }

    // MARK: - Content

    /// Edits the current record or item.
    public mutating func edit(_ markdown: String) {
        switch current {
        case .project: break
        case .record: progress.recordEdit = markdown
        case let .item(id): progress.edits[id] = markdown
        }
    }

    /// Drops the current step's edit.
    public mutating func undoEdits() {
        switch current {
        case .project: break
        case .record: progress.recordEdit = nil
        case let .item(id): progress.edits[id] = nil
        }
    }

    /// The record is shown without the distilled section (`commitOps` adds
    /// it with the approved items). `timeZone` defaults to the session's.
    public func markdown(for step: Step, timeZone: TimeZone? = nil) -> String {
        switch step {
        case .project:
            return ""
        case .record:
            if let edit = progress.recordEdit { return edit }
            let tz = timeZone ?? self.timeZone
            return OKMeetingRenderer.renderRecord(proposal.note, project: recordProject, paths: recordPaths(tz), timeZone: tz)
        case let .item(id):
            return progress.edits[id] ?? item(id)?.markdown ?? ""
        }
    }

    /// What the diff is shown against: the doc an update replaces, or the
    /// version a conflict found in the vault.
    public func previousMarkdown(for step: Step) -> String? {
        switch step {
        case .project: nil
        case .record: proposal.existingRecordContent
        case let .item(id): item(id)?.baseContent
        }
    }

    // MARK: - Proposal changes

    /// After a redistillation (or a project change without the model): each
    /// new item takes the decision and edit of the old item with the same
    /// `action` and `path`. A carried approval only holds if its stamp
    /// matches the new item (same Markdown and same `baseHash`). When the
    /// record's destination changed (`paths` or project, as `redistill` and
    /// `repath` recompute them), the carried edits are retargeted first (see
    /// `retarget`) and the record hashes, which described the old files, are
    /// dropped. Returns the items to review and moves to the first pending step.
    @discardableResult
    public mutating func replaceProposal(_ p: MeetingProposal) -> [UUID] {
        var decisions: [UUID: OKItemDecision] = [:]
        var edits: [UUID: String] = [:]
        for item in p.items {
            guard let old = proposal.items.first(where: { $0.action == item.action && $0.path == item.path }) else { continue }
            decisions[item.id] = progress.decisions[old.id]
            edits[item.id] = progress.edits[old.id]
        }
        let oldPaths = proposal.paths
        let shownPaths = recordPaths(timeZone)
        let shownProject = recordProject
        proposal = p
        progress.generation = p.generation
        progress.decisions = decisions
        progress.edits = edits
        if p.paths != oldPaths, p.fixedPaths == nil {
            proposal.existingRecordHash = nil
            proposal.existingTranscriptHash = nil
            proposal.existingRecordContent = nil
        }
        if recordPaths(timeZone) != shownPaths || recordProject != shownProject {
            retarget(from: shownPaths, project: shownProject)
        }
        moveToFirstPending()
        return p.items.filter { !isDecided($0.id) }.map(\.id)
    }

    /// Another meeting took the record's name since the proposal was made:
    /// moves the record and transcript to the next free name and retargets
    /// the edits and decisions (see `retarget`). `true` → the caller shows a
    /// notice and doesn't write. Never moves `fixedPaths`.
    @discardableResult
    public mutating func relocateIfTaken(vault: URL, fileManager: FileManager = .default) -> Bool {
        guard proposal.fixedPaths == nil, let old = proposal.paths, let project = proposal.project else { return false }
        let note = proposal.note
        func taken(_ relPath: String) -> Bool {
            let url = vault.appendingPathComponent(relPath)
            return fileManager.fileExists(atPath: url.path) && !MeetingNoteWriter.belongs(url, to: note.id)
        }
        guard taken(old.record) || taken(old.transcript) else { return false }
        let new = OKMeetingPaths.available(project: project, startedAt: note.startedAt, title: note.summary.title, id: note.id,
                                           vault: vault, timeZone: timeZone, fileManager: fileManager)
        guard new != old else { return false }

        proposal.paths = new
        // `available` only returns a taken name when it holds this meeting.
        let ownRecord = try? Data(contentsOf: vault.appendingPathComponent(new.record))
        proposal.existingRecordHash = ownRecord.map(OKPath.contentHash)
        proposal.existingRecordContent = ownRecord.map { String(decoding: $0, as: UTF8.self) }
        proposal.existingTranscriptHash = Self.hash(of: new.transcript, in: vault)
        retarget(from: old, project: project)
        moveToFirstPending()
        return true
    }

    /// The writer's conflicts: an item goes back to review as an update of
    /// the version now in the vault (a create whose path appeared becomes an
    /// update of that file). A record or transcript conflict (or a missing
    /// dependency) brings the record back to be written and reviewed. A
    /// conflict on `index.md`/`README.md` changes nothing: the caller
    /// rebuilds the ops.
    public mutating func applyConflicts(_ conflicts: [OKConflict]) {
        let recordConflict = proposal.absorb(conflicts)
        let ids = Set(conflicts.compactMap(\.itemID))
        for id in ids { progress.decisions[id] = nil }
        if recordConflict {
            progress.recordApproval = nil
            move(to: .record)
        } else if let first = proposal.items.first(where: { ids.contains($0.id) }) {
            move(to: .item(first.id))
        }
    }

    // MARK: - Commit

    /// With `recordWritten`, the record and transcript the items cite: the
    /// transaction doesn't write them but they must exist when it ends.
    /// Otherwise `[]`, since they are ops.
    public func commitDependencies() -> [String] {
        guard proposal.recordWritten, let paths = proposal.paths else { return [] }
        return [paths.record] + (proposal.note.transcript != nil ? [paths.transcript] : [])
    }

    /// The vault operations for what was approved, always on the persisted
    /// `paths`: project scaffolding, transcript, record (with the approved
    /// items in "Conhecimento destilado"), approved items, and the project
    /// index for new docs. An update expects the hash the user saw.
    public func commitOps(vault: URL, now: Date, timeZone: TimeZone? = nil, fileManager: FileManager = .default) throws -> [OKVaultOp] {
        guard proposal.vault?.matches(vault) == true else { throw CommitError.vaultMismatch }
        guard let paths = proposal.paths, let project = proposal.project else { throw CommitError.noPaths }
        guard canCommit else { throw CommitError.notReady }
        let tz = timeZone ?? self.timeZone
        let note = proposal.note
        let approved = proposal.items.filter { isApproved($0.id) }
        let indexLinks = approved.filter { $0.action == .new }.map { (type: $0.type, title: title(of: $0), path: $0.path) }
        let created = progress.newProject.flatMap { $0.slug == project ? $0 : nil }
        var ops: [OKVaultOp] = []

        if let created {
            ops += OKProjectScaffold.folderMetadata(project: project).map { .createIfMissing(path: $0.path, content: $0.content) }
            let index = OKProjectScaffold.index(project: project, description: created.description)
            ops.append(.create(path: index.path, content: OKProjectScaffold.indexAddingLinks(index.content, links: indexLinks), itemID: nil))
            let readme = try Self.read("README.md", in: vault, fileManager)
            let content = OKProjectScaffold.readmeAddingProject(readme?.text ?? "", project: project, description: created.description)
            ops.append(Self.write("README.md", content, expected: readme?.hash, itemID: nil))
        } else if !proposal.recordWritten {
            let meetings = "\(project)/\(OKMeetingPaths.meetingsFolder)/"
            ops += OKProjectScaffold.folderMetadata(project: project)
                .filter { $0.path.hasPrefix(meetings) }
                .map { .createIfMissing(path: $0.path, content: $0.content) }
        }

        if !proposal.recordWritten {
            if let transcript = note.transcript {
                let content = OKMeetingRenderer.renderTranscript(note, transcript: transcript, project: project, paths: paths, timeZone: tz)
                ops.append(Self.write(paths.transcript, content, expected: proposal.existingTranscriptHash, itemID: nil))
            }
            let links = approved.map { OKDistilledLink(title: title(of: $0), path: $0.path) }
            let record = OKMeetingRenderer.appendingDistilled(links, to: markdown(for: .record, timeZone: tz), paths: paths)
            guard OKFrontmatter.isValidDocument(record) else { throw CommitError.invalidFrontmatter(paths.record) }
            ops.append(Self.write(paths.record, record, expected: proposal.existingRecordHash, itemID: nil))
        }

        for item in approved {
            let content = markdown(for: .item(item.id))
            guard OKFrontmatter.isValidDocument(content) else { throw CommitError.invalidFrontmatter(item.path) }
            ops.append(Self.write(item.path, content, expected: item.action == .update ? item.baseHash : nil, itemID: item.id))
        }

        if created == nil, !indexLinks.isEmpty {
            let path = "\(project)/index.md"
            if let index = try Self.read(path, in: vault, fileManager) {
                ops.append(.update(path: path, content: OKProjectScaffold.indexAddingLinks(index.text, links: indexLinks),
                                   expectedHash: index.hash, itemID: nil))
            }
        }
        return ops
    }

    /// The receipt the writer fills (`written`) and keeps in the journal.
    public func receiptDraft(vault: OKVaultIdentity) -> OKCommitReceipt {
        OKCommitReceipt(meetingID: proposal.meetingID, proposalGeneration: generation, vault: vault,
                        project: recordProject, paths: recordPaths(timeZone))
    }

    // MARK: - Helpers

    /// The record moved from `old` in `oldProject` to the current paths and
    /// project. Rewrites each item's source link to the record (generated
    /// and edited), unless the doc it updates already cited that path (a
    /// legitimate reference to the other meeting, left to the user), and
    /// drops the decision of every item whose Markdown changed or still
    /// cites the old record. In an edited record it rewrites the transcript
    /// link and, for a new project, the `project` and default `tags`. The
    /// record's approval is dropped: its destination changed.
    private mutating func retarget(from old: OKMeetingPaths, project oldProject: String) {
        let new = recordPaths(timeZone)
        let project = recordProject
        let oldName = (old.record as NSString).lastPathComponent
        let renamed = oldName != (new.record as NSString).lastPathComponent
        for i in proposal.items.indices {
            let item = proposal.items[i]
            let from = OKPath.relativeLink(from: item.path, to: old.record)
            let to = OKPath.relativeLink(from: item.path, to: new.record)
            guard from != to else { continue }
            let citesOther = item.baseContent?.contains(from) == true
            func rewrite(_ md: String) -> String {
                citesOther ? md : md.replacingOccurrences(of: "](\(from))", with: "](\(to))")
            }
            let shown = markdown(for: .item(item.id))
            proposal.items[i].markdown = rewrite(item.markdown)
            if let edit = progress.edits[item.id] { progress.edits[item.id] = rewrite(edit) }
            let after = markdown(for: .item(item.id))
            if after != shown || after.contains("](\(from))") || (renamed && after.contains(oldName)) {
                progress.decisions[item.id] = nil
            }
        }
        if var edit = progress.recordEdit {
            edit = edit.replacingOccurrences(of: OKPath.relativeLink(from: old.record, to: old.transcript),
                                             with: OKPath.relativeLink(from: new.record, to: new.transcript))
            if project != oldProject {
                if OKFrontmatter.scalar("project", in: edit) == oldProject {
                    edit = OKFrontmatter.setting("project", to: project, in: edit)
                }
                if OKFrontmatter.scalar("tags", in: edit) == "[reuniao, \(oldProject)]" {
                    edit = OKFrontmatter.setting("tags", to: "[reuniao, \(project)]", in: edit)
                }
            }
            progress.recordEdit = edit
        }
        progress.recordApproval = nil
    }

    mutating func moveToFirstPending() {
        progress.stepIndex = steps.firstIndex { step in
            switch step {
            case .project: chosenProject == nil || needsRedistill
            case .record: !recordApproved
            case let .item(id): !isDecided(id)
            }
        } ?? steps.count
    }

    private mutating func move(to step: Step) {
        if let index = steps.firstIndex(of: step) { progress.stepIndex = index }
    }

    private mutating func advance() {
        progress.stepIndex = min(progress.stepIndex + 1, steps.count)
    }

    private func isDecided(_ id: UUID) -> Bool {
        isApproved(id) || progress.decisions[id] == .skipped
    }

    private func item(_ id: UUID) -> OKProposedItem? {
        proposal.items.first { $0.id == id }
    }

    /// The doc's frontmatter title as shown now, else the planned title.
    private func title(of item: OKProposedItem) -> String {
        let title = OKFrontmatter.scalar("title", in: markdown(for: .item(item.id))) ?? ""
        return title.isEmpty ? item.title : title
    }

    private var recordProject: String { proposal.project ?? chosenProject ?? "" }

    private func recordPaths(_ timeZone: TimeZone) -> OKMeetingPaths {
        proposal.paths ?? OKMeetingPaths.make(project: recordProject, startedAt: proposal.note.startedAt,
                                              title: proposal.note.summary.title, timeZone: timeZone)
    }

    static func hash(_ markdown: String) -> String {
        OKPath.contentHash(Data(markdown.utf8))
    }

    static func hash(of relPath: String, in vault: URL) -> String? {
        (try? Data(contentsOf: vault.appendingPathComponent(relPath))).map(OKPath.contentHash)
    }

    /// `create` when nothing was there, else `update` against what was read.
    private static func write(_ path: String, _ content: String, expected: String?, itemID: UUID?) -> OKVaultOp {
        if let expected { return .update(path: path, content: content, expectedHash: expected, itemID: itemID) }
        return .create(path: path, content: content, itemID: itemID)
    }

    private static func read(_ relPath: String, in vault: URL, _ fileManager: FileManager) throws -> (text: String, hash: String)? {
        let url = vault.appendingPathComponent(relPath)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return (String(decoding: data, as: UTF8.self), OKPath.contentHash(data))
    }
}

extension MeetingProposal {
    /// Applies the writer's conflicts to the items and the record (see
    /// `OKApprovalSession.applyConflicts`). `true` when the record or the
    /// transcript conflicted.
    mutating func absorb(_ conflicts: [OKConflict]) -> Bool {
        var recordConflict = false
        for conflict in conflicts {
            if let id = conflict.itemID {
                guard let i = items.firstIndex(where: { $0.id == id }) else { continue }
                items[i].conflict = true
                items[i].action = conflict.currentHash == nil ? .new : .update
                items[i].baseHash = conflict.currentHash
                items[i].baseContent = conflict.currentContent
            } else if let paths, conflict.path == paths.record || conflict.path == paths.transcript {
                recordWritten = false
                if conflict.path == paths.record {
                    existingRecordHash = conflict.currentHash
                    existingRecordContent = conflict.currentContent
                } else {
                    existingTranscriptHash = conflict.currentHash
                }
                recordConflict = true
            }
        }
        return recordConflict
    }
}
