import AppKit
import Core
import Foundation
import Observation
import os

/// The approval window's state for one pending meeting: the session read
/// from the meeting's directory, every change saved back over the same
/// proposal generation, and the commit into the vault. A reprocess or a
/// replacement of the proposal on disk always wins: the window reloads from
/// disk and never writes an older generation.
@MainActor
@Observable
final class ApprovalViewModel {
    enum Tab { case preview, editor }

    var session: OKApprovalSession?
    var projects: [OKProject] = []
    var search = ""
    var isDistilling = false
    /// What runs while `isDistilling` ("Destilando contra p5…").
    var progressText: String?
    var banner: String?
    /// The proposal was prepared for another vault: only the notice and
    /// `prepareForCurrentVault()` are available.
    var vaultMismatch: (prepared: String, current: String)?
    /// A vault write of this meeting left its journal: only the notice.
    var journalPending = false
    var tab: Tab = .preview
    /// Set once the meeting is in the vault: nothing here applies anymore.
    private(set) var committed = false

    var filteredProjects: [OKProject] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return projects }
        return projects.filter {
            $0.slug.localizedCaseInsensitiveContains(query) || $0.title.localizedCaseInsensitiveContains(query)
        }
    }

    /// Steps and commit are off while the window only shows a notice or works.
    var isBlocked: Bool { session == nil || vaultMismatch != nil || journalPending || isDistilling || committed }

    var currentHasEdit: Bool {
        guard let session else { return false }
        switch session.current {
        case .project: return false
        case .record: return session.progress.recordEdit != nil
        case let .item(id): return session.progress.edits[id] != nil
        }
    }

    @ObservationIgnored let directory: URL
    @ObservationIgnored private let configStore: ConfigStore
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private let pending: PendingApprovals
    @ObservationIgnored private let assistantFactory: (String?) -> (any OKAssistant)?
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let writerFault: (@Sendable (OKFaultPoint) throws -> Void)?
    @ObservationIgnored private var vault = OKVault.unset
    @ObservationIgnored private var claudeCLIPath: String?

    private static let log = Logger(subsystem: "com.voicetype.app", category: "approvals")

    init(
        directory: URL, configStore: ConfigStore, notifier: Notifier, pending: PendingApprovals,
        assistantFactory: @escaping (String?) -> (any OKAssistant)?,
        now: @escaping @Sendable () -> Date = { Date() },
        writerFault: (@Sendable (OKFaultPoint) throws -> Void)? = nil
    ) {
        self.directory = directory
        self.configStore = configStore
        self.notifier = notifier
        self.pending = pending
        self.assistantFactory = assistantFactory
        self.now = now
        self.writerFault = writerFault
        observePending()
    }

    // MARK: - Loading

    /// Settles an interrupted vault write first, then mounts the session and,
    /// when the distilled items are stale, distills them again.
    func load() async {
        banner = nil
        let cfg = (try? await configStore.load()) ?? AppConfig()
        vault = OKVault.url(cfg.openKnowledgeVaultPath)
        claudeCLIPath = cfg.claudeCLIPath

        if MeetingProposalStore.hasJournal(directory) {
            pending.recoverMeeting(directory)
            if MeetingProposalStore.hasJournal(directory) {
                session = nil
                vaultMismatch = nil
                journalPending = true
                return
            }
        }
        journalPending = false
        guard mount() else {
            banner = ApprovalStrings.gone
            return
        }
        guard vaultMismatch == nil, let s = session, !s.needsRedistill, let project = s.proposal.project,
              let docs = try? OKVaultCatalog.docs(project: project, in: vault),
              OKProposalBuilder.isStale(s.proposal, currentFingerprint: OKVaultCatalog.fingerprint(docs), now: now())
        else { return }
        await run(ApprovalStrings.distilling(project)) {
            do {
                var next = s
                next.replaceProposal(try await self.distill(s.proposal, project: project))
                if self.persist(next) { self.banner = ApprovalStrings.redistilled }
            } catch {
                self.banner = ApprovalStrings.redistillFailed(Self.message(error))
            }
        }
    }

    /// Reads the proposal and progress from disk (progress of another
    /// generation is ignored), the vault check and the projects. `false`
    /// when the proposal is gone.
    @discardableResult
    private func mount() -> Bool {
        guard let proposal = MeetingProposalStore.load(directory) else {
            session = nil
            vaultMismatch = nil
            return false
        }
        session = OKApprovalSession(proposal: proposal, progress: OKApprovalProgress.load(directory))
        if proposal.vault?.matches(vault) == true {
            vaultMismatch = nil
        } else {
            vaultMismatch = (proposal.vault?.root ?? ApprovalStrings.unknownVault, vault.path)
        }
        projects = (try? OKVaultCatalog.projects(in: vault)) ?? []
        tab = .preview
        return true
    }

    /// The proposal on disk was replaced (reprocess, another window): the
    /// review starts over from it, without the old progress.
    func reloadAfterReplacement() {
        guard mount() else {
            banner = ApprovalStrings.gone
            return
        }
        banner = ApprovalStrings.reprocessed
    }

    /// Reloads as soon as the menu's list shows another generation (or none)
    /// for this meeting, without waiting for a click.
    private func observePending() {
        withObservationTracking {
            _ = pending.items
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observePending()
                guard !self.committed, let session = self.session,
                      MeetingProposalStore.load(self.directory)?.generation != session.generation else { return }
                self.reloadAfterReplacement()
            }
        }
    }

    // MARK: - Project

    func choose(_ slug: String) async {
        guard !isBlocked, var s = session else { return }
        do {
            // Confirming again the project created here keeps it new: only
            // choosing another project drops its description and scaffolding.
            if s.progress.newProject?.slug != slug { try s.chooseProject(slug) }
        } catch {
            banner = (error as? OKApprovalSession.ProjectError).map(ApprovalStrings.projectError) ?? error.localizedDescription
            return
        }
        guard s.needsRedistill else {
            persist(s)
            return
        }
        await prepare(s, for: slug)
    }

    /// Validation errors (`OKApprovalSession.ProjectError`) are thrown for
    /// the sheet to show.
    func createProject(slug: String, description: String) async throws {
        guard !isBlocked, var s = session else { return }
        try s.chooseNewProject(slug: slug, description: description, existing: projects)
        await prepare(s, for: slug)
    }

    /// Distills again for the proposal's project after a failure.
    func retryDistillation() async {
        guard !isBlocked, let s = session, s.proposal.summaryFailure == nil, let project = s.chosenProject else { return }
        banner = nil
        await prepare(s, for: project)
    }

    /// Moves the proposal to `project`: without a summary there's nothing to
    /// distill (`repath`); otherwise `redistill`, and when the model can't
    /// (no CLI, logged out, limit) the record alone stays approvable in that
    /// project, with no automatic retry.
    private func prepare(_ s: OKApprovalSession, for project: String) async {
        var next = s
        guard s.proposal.summaryFailure == nil else {
            next.replaceProposal(OKProposalBuilder.repath(s.proposal, project: project, vault: vault, timeZone: s.timeZone))
            persist(next)
            return
        }
        await run(ApprovalStrings.distilling(project)) {
            do {
                next.replaceProposal(try await self.distill(s.proposal, project: project))
                if self.persist(next) { self.banner = nil }
            } catch {
                let message = Self.message(error)
                // Fixed paths never move: the proposal stays as it is.
                guard s.proposal.fixedPaths == nil else {
                    self.banner = ApprovalStrings.distillFailed(project, message)
                    return
                }
                var q = OKProposalBuilder.repath(s.proposal, project: project, vault: self.vault, timeZone: s.timeZone)
                q.distillationError = message
                next.replaceProposal(q)
                if self.persist(next) { self.banner = ApprovalStrings.distillFailed(project, message) }
            }
        }
    }

    // MARK: - Navigation and content

    func approve() { mutate { $0.approve() } }
    func skip() { mutate { $0.skip() } }
    func back() { mutate { $0.back() } }
    func edit(_ s: String) { mutate { $0.edit(s) } }
    func undoEdits() { mutate { $0.undoEdits() } }

    private func mutate(_ change: (inout OKApprovalSession) -> Void) {
        guard !isBlocked, var s = session else { return }
        let step = s.current
        change(&s)
        if persist(s), s.current != step { tab = .preview }
    }

    /// Saves `s` over its own generation (the proposal only when it changed)
    /// and makes it the session. Another generation on disk → the change is
    /// dropped and the window reloads.
    @discardableResult
    private func persist(_ s: OKApprovalSession) -> Bool {
        let proposalChanged = s.proposal != session?.proposal
        do {
            try MeetingProposalStore.withLock {
                if proposalChanged { try MeetingProposalStore.save(s.proposal, in: directory) }
                try s.progress.save(in: directory)
            }
            session = s
            return true
        } catch MeetingProposalStore.StoreError.generationChanged {
            reloadAfterReplacement()
        } catch {
            banner = error.localizedDescription
        }
        return false
    }

    // MARK: - Another vault

    /// Builds a fresh proposal for the current vault (new generation) and
    /// replaces this one only if it's still the generation on disk.
    func prepareForCurrentVault() async {
        guard let s = session, vaultMismatch != nil, !journalPending, !isDistilling else { return }
        let old = s.generation
        let state = (try? JSONDecoder().decode(
            MeetingPipelineState.self, from: Data(contentsOf: directory.appendingPathComponent(MeetingPipelineState.stateFileName))
        )) ?? MeetingPipelineState(noteID: s.proposal.meetingID)
        let target = vault
        await run(ApprovalStrings.preparing(target.path)) {
            let fresh = await self.builder().rebuild(s.proposal, state: state, vault: target, now: self.now())
            do {
                try MeetingProposalStore.replace(fresh, in: self.directory, expecting: old)
                self.mount()
                self.banner = nil
            } catch MeetingProposalStore.StoreError.generationChanged {
                self.reloadAfterReplacement()
            } catch MeetingProposalStore.StoreError.meetingBusy {
                self.session = nil
                self.journalPending = true
            } catch {
                self.banner = error.localizedDescription
            }
        }
    }

    // MARK: - Commit

    /// Writes what was approved. `true` only when the meeting is in the
    /// vault and its local state is concluded; anything else leaves the
    /// vault untouched (or settled by the writer) and explains in `banner`.
    func commit() async -> Bool {
        guard !isBlocked else { return false }
        if MeetingProposalStore.hasJournal(directory) {
            journalPending = true
            return false
        }
        var preconditionRetried = false
        var opsRebuilt = false
        while true {
            guard var s = session, s.canCommit else { return false }

            // 2. Catalog and age, only with distilled knowledge to write.
            if s.hasApprovedItems, let project = s.proposal.project {
                let docs: [OKDocEntry]
                do {
                    docs = try OKVaultCatalog.docs(project: project, in: vault)
                } catch {
                    banner = error.localizedDescription
                    return false
                }
                if OKProposalBuilder.isStale(s.proposal, currentFingerprint: OKVaultCatalog.fingerprint(docs), now: now()) {
                    await run(ApprovalStrings.distilling(project)) {
                        do {
                            s.replaceProposal(try await self.distill(s.proposal, project: project))
                            if self.persist(s) { self.banner = ApprovalStrings.redistilled }
                        } catch {
                            self.banner = ApprovalStrings.redistillFailed(Self.message(error))
                        }
                    }
                    return false
                }
            }

            // 3. The record's name taken by another meeting meanwhile.
            let before = s.paths?.record
            if s.relocateIfTaken(vault: vault) {
                if persist(s) { banner = ApprovalStrings.relocated(from: before ?? "", to: s.paths?.record ?? "") }
                return false
            }

            // 4. The transaction, under the proposal lock.
            let result: Outcome
            do {
                result = try write(s)
            } catch let OKVaultWriter.WriteError.incomplete(paths) {
                journalPending = true
                banner = ApprovalStrings.incomplete(paths)
                return false
            } catch {
                Self.log.error("approval commit failed: \(String(describing: error), privacy: .public)")
                banner = error.localizedDescription
                return false
            }

            switch result {
            case .reloaded:
                return false
            case let .done(receipt, kept, finalizeError):
                committed = true
                pending.refresh()
                if let finalizeError {
                    banner = ApprovalStrings.finalizeFailed(finalizeError)
                    return false
                }
                await notifier.success(title: ApprovalStrings.committedTitle, body: receipt.paths.record)
                if !kept.isEmpty {
                    await notifier.error(title: ApprovalStrings.divergedTitle,
                                         body: ApprovalStrings.divergedBody(title: s.proposal.note.summary.title, kept))
                }
                return true
            case let .partial(count, preserved):
                pending.refresh()
                mount()
                banner = ApprovalStrings.partial(count, preserved: preserved)
                return false
            case .preconditionFailed:
                // 5. Back to the catalog check once.
                guard !preconditionRetried else {
                    banner = ApprovalStrings.changedDuringCommit
                    return false
                }
                preconditionRetried = true
            case let .conflicts(conflicts, divergences):
                let preserved = divergences.compactMap(\.preservedCopy)
                // 6. Only the index or README changed: rebuild the ops once.
                if !opsRebuilt, preserved.isEmpty, conflicts.allSatisfy({ isIndexOrReadme($0, s) }) {
                    opsRebuilt = true
                    continue
                }
                // 7. Back to review with the versions now in the vault.
                s.applyConflicts(conflicts)
                if conflicts.contains(where: { $0.path == s.paths?.record || $0.path == s.paths?.transcript }) {
                    s.relocateIfTaken(vault: vault)
                }
                if persist(s) { banner = ApprovalStrings.conflicts(conflicts.count, preserved: preserved) }
                return false
            }
        }
    }

    private enum Outcome {
        case reloaded
        /// `kept`: the outside versions `finish` moved aside.
        case done(OKCommitReceipt, kept: [OKDivergence], finalizeError: String?)
        case partial(count: Int, preserved: [String])
        case preconditionFailed
        case conflicts([OKConflict], [OKDivergence])
    }

    /// Generation check, `OKVaultWriter.commit` and the local conclusion,
    /// all inside `MeetingProposalStore.withLock`, so a reprocess can't swap
    /// the proposal in between.
    private func write(_ s: OKApprovalSession) throws -> Outcome {
        let vault = vault
        let now = now
        let ops = try s.commitOps(vault: vault, now: now())
        return try MeetingProposalStore.withLock {
            guard MeetingProposalStore.load(directory)?.generation == s.generation else {
                reloadAfterReplacement()
                return .reloaded
            }
            if MeetingProposalStore.hasJournal(directory) {
                journalPending = true
                return .reloaded
            }
            guard let identity = s.proposal.vault else { throw OKApprovalSession.CommitError.vaultMismatch }
            var writer = OKVaultWriter(vault: vault, identity: identity,
                                       journalDirectory: directory.appendingPathComponent(MeetingProposalStore.journalFolder, isDirectory: true))
            writer.fault = writerFault
            let result = try writer.commit(
                ops, dependencies: s.commitDependencies(), receipt: s.receiptDraft(vault: identity),
                precondition: { Self.stillValid(s, vault: vault, now: now()) }
            )
            switch result {
            case let .committed(receipt):
                do {
                    let kept = try OKApprovalFinalizer.finalize(meetingDirectory: directory, receipt: receipt)
                    return .done(receipt, kept: kept, finalizeError: nil)
                } catch {
                    Self.log.error("approval finalize failed: \(String(describing: error), privacy: .public)")
                    return .done(receipt, kept: [], finalizeError: error.localizedDescription)
                }
            case let .partial(receipt, conflicts, _):
                // `finish` reports every outside version, where it now is.
                let kept = try OKApprovalFinalizer.finalizePartial(meetingDirectory: directory, receipt: receipt, conflicts: conflicts)
                return .partial(count: conflicts.count, preserved: kept.compactMap(\.preservedCopy))
            case let .conflicts(conflicts, divergences):
                return .conflicts(conflicts, divergences)
            case .preconditionFailed:
                return .preconditionFailed
            }
        }
    }

    /// Runs with the intent saved, before the first rename: the record's
    /// name is still free and, with distilled items, the catalog and the
    /// proposal's age still hold.
    private nonisolated static func stillValid(_ s: OKApprovalSession, vault: URL, now: Date) -> Bool {
        var probe = s
        if probe.relocateIfTaken(vault: vault) { return false }
        guard s.hasApprovedItems, let project = s.proposal.project else { return true }
        guard let docs = try? OKVaultCatalog.docs(project: project, in: vault) else { return false }
        return !OKProposalBuilder.isStale(s.proposal, currentFingerprint: OKVaultCatalog.fingerprint(docs), now: now)
    }

    private func isIndexOrReadme(_ conflict: OKConflict, _ s: OKApprovalSession) -> Bool {
        conflict.itemID == nil && (conflict.path == "README.md" || conflict.path == "\(s.proposal.project ?? "")/index.md")
    }

    // MARK: - Helpers

    private func builder() -> OKProposalBuilder {
        OKProposalBuilder(assistant: assistantFactory(claudeCLIPath), user: NSFullUserName())
    }

    private func distill(_ p: MeetingProposal, project: String) async throws -> MeetingProposal {
        try await builder().redistill(p, project: project, vault: vault, now: now())
    }

    /// Shows `text` with a spinner and the buttons off while `body` runs.
    private func run(_ text: String, _ body: () async -> Void) async {
        isDistilling = true
        progressText = text
        await body()
        isDistilling = false
        progressText = nil
    }

    private static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
