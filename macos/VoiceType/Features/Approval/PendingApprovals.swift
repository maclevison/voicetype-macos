import AppKit
import Core
import Foundation
import os

/// The OpenKnowledge meetings waiting for approval, as the menu lists them,
/// and the recovery of vault writes that a crash or a disk error left
/// unfinished. Recovery always runs in the vault recorded in the meeting's
/// journal, never the one in the current config, and only reports errors:
/// a pending meeting never asks for attention by itself.
@MainActor
@Observable
final class PendingApprovals {
    private(set) var items: [PendingMeeting] = []

    @ObservationIgnored private let base: URL
    @ObservationIgnored private let reportError: @MainActor (_ title: String, _ body: String) -> Void
    /// Test hook passed to `OKVaultWriter.recover`; `nil` in production.
    @ObservationIgnored var recoverFault: (@Sendable (OKFaultPoint) throws -> Void)?

    private static let log = Logger(subsystem: "com.voicetype.app", category: "approvals")

    /// Recovery runs at launch, before the notification authorization
    /// comes back, and a `Notifier` drops everything until then: each notice
    /// waits for `bootstrap()` (the same request the app delegate starts).
    convenience init(base: URL = MeetingRecorder.baseDirectory, notifier: Notifier) {
        self.init(base: base) { title, body in
            Task {
                await notifier.bootstrap()
                await notifier.error(title: title, body: body)
            }
        }
    }

    init(base: URL = MeetingRecorder.baseDirectory, reportError: @escaping @MainActor (_ title: String, _ body: String) -> Void) {
        self.base = base
        self.reportError = reportError
    }

    func refresh() {
        items = PendingMeetings.scan(base: base)
    }

    /// Drops the proposal and the window's progress; the meeting's audio,
    /// transcript and `pipeline.json` stay. Refused while a vault write left
    /// a journal: it still has to be finished or undone.
    func discard(_ item: PendingMeeting) {
        let removed = MeetingProposalStore.withLock {
            guard !MeetingProposalStore.hasJournal(item.directory) else { return false }
            MeetingProposalStore.remove(item.directory, generation: item.generation)
            return true
        }
        refresh()
        guard !removed else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = ApprovalStrings.discardBusyTitle(item.title)
        alert.informativeText = ApprovalStrings.discardBusyBody
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// At launch: finishes or undoes every interrupted vault write, then lists.
    func bootstrap() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs where MeetingProposalStore.hasJournal(dir) {
            recoverMeeting(dir)
        }
        refresh()
    }

    /// Settles the meeting's journal (`ok-commit/`), if any: a committed or
    /// completed write is finalized, an undone one goes back to review, and
    /// anything that can't be settled now keeps the journal for the next try.
    func recoverMeeting(_ dir: URL) {
        let notices = MeetingProposalStore.withLock { settle(dir) }
        for notice in notices {
            reportError(notice.title, notice.body)
        }
        refresh()
    }

    // MARK: - Recovery

    private struct Notice {
        var title: String
        var body: String
    }

    /// Runs inside `MeetingProposalStore.withLock`.
    private func settle(_ dir: URL) -> [Notice] {
        let journal = dir.appendingPathComponent(MeetingProposalStore.journalFolder, isDirectory: true)
        let title = MeetingProposalStore.load(dir)?.note.summary.title ?? dir.lastPathComponent
        do {
            switch try OKVaultWriter.recover(journalDirectory: journal, fault: recoverFault) {
            case .nothing:
                return []
            case let .committed(receipt):
                let kept = try OKApprovalFinalizer.finalize(meetingDirectory: dir, receipt: receipt)
                Self.log.info("recovered vault write finalized: \(dir.path, privacy: .public) preserved=\(kept.count)")
                return kept.isEmpty ? [] : [Notice(title: ApprovalStrings.divergedTitle, body: ApprovalStrings.divergedBody(title: title, kept))]
            case let .partial(receipt, conflicts, _):
                // `finish` reports every outside version, where it now is.
                let kept = try OKApprovalFinalizer.finalizePartial(meetingDirectory: dir, receipt: receipt, conflicts: conflicts)
                let preserved = kept.compactMap(\.preservedCopy)
                return [Notice(title: ApprovalStrings.partialTitle,
                               body: ApprovalStrings.partialBody(count: conflicts.count, title: title, preserved: preserved))]
            case let .rolledBack(conflicts, divergences):
                var notices: [Notice] = []
                if !conflicts.isEmpty {
                    try returnToReview(dir, conflicts)
                    notices.append(Notice(title: ApprovalStrings.rolledBackTitle,
                                          body: ApprovalStrings.rolledBackBody(count: conflicts.count, title: title)))
                }
                if !divergences.isEmpty {
                    let copies = Set(divergences.compactMap { $0.preservedCopy.map { ($0 as NSString).deletingLastPathComponent } })
                    notices.append(Notice(title: ApprovalStrings.interruptedTitle,
                                          body: ApprovalStrings.divergencesBody(paths: divergences.map(\.path), copies: copies.sorted())))
                }
                return notices
            case let .vaultUnavailable(root):
                return [Notice(title: ApprovalStrings.interruptedTitle, body: ApprovalStrings.vaultUnavailableBody(root))]
            }
        } catch let OKVaultWriter.WriteError.incomplete(paths) {
            return [Notice(title: ApprovalStrings.incompleteTitle, body: ApprovalStrings.incompleteBody(paths))]
        } catch {
            Self.log.error("vault recovery failed: \(dir.path, privacy: .public) \(String(describing: error), privacy: .public)")
            return [Notice(title: ApprovalStrings.interruptedTitle, body: ApprovalStrings.recoveryFailedBody(error.localizedDescription))]
        }
    }

    /// An undone write whose docs changed meanwhile: the proposal takes the
    /// current versions (so the approval stamp no longer holds and the diff
    /// is against what's in the vault now) and the progress moves to them.
    private func returnToReview(_ dir: URL, _ conflicts: [OKConflict]) throws {
        guard let proposal = MeetingProposalStore.load(dir) else { return }
        var session = OKApprovalSession(proposal: proposal, progress: OKApprovalProgress.load(dir))
        session.applyConflicts(conflicts)
        try MeetingProposalStore.save(session.proposal, in: dir)
        try session.progress.save(in: dir)
    }
}
