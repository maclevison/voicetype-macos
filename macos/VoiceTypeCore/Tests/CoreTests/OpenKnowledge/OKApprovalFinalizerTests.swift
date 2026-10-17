import Foundation
import Testing
@testable import Core

@Suite("OKApprovalFinalizer")
struct OKApprovalFinalizerTests {
    private let utc = TimeZone(identifier: "UTC")!
    // 2026-10-16 14:30:00 UTC
    private let date = Date(timeIntervalSince1970: 1_792_161_000)
    private let fm = FileManager.default
    private let gotchaPath = "p5/gotchas/g.md"

    private func h(_ text: String) -> String { OKPath.contentHash(Data(text.utf8)) }

    private func makeTemp() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func put(_ text: String, _ relPath: String, in root: URL) throws {
        let url = root.appendingPathComponent(relPath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func makeVault() throws -> URL {
        let vault = try makeTemp()
        try fm.createDirectory(at: vault.appendingPathComponent(".ok"), withIntermediateDirectories: true)
        try put("---\ntitle: p5\ndescription: Projeto p5.\ntype: indice\nproject: p5\n---\n# p5\n", "p5/index.md", in: vault)
        try put("old gotcha\n", gotchaPath, in: vault)
        return vault
    }

    /// A new decision and an update of the gotcha.
    private func proposal(vault: URL, meetingID: UUID) throws -> MeetingProposal {
        let note = MeetingNote(startedAt: date, duration: 1800, summary: MeetingSummary(title: "Sprint review", summary: "Revisamos."),
                               transcript: "Você: oi")
        let paths = OKMeetingPaths.make(project: "p5", startedAt: date, title: "Sprint review", timeZone: utc)
        return MeetingProposal(
            meetingID: meetingID, note: note, vault: try OKVaultIdentity.of(vault), suggestedProject: "p5", project: "p5", paths: paths,
            items: [
                OKProposedItem(action: .new, type: .decisao, path: "p5/decisoes/usar-fila.md", title: "Usar fila",
                               markdown: "---\ntitle: Usar fila\ndescription: d\ntype: decisao\nproject: p5\n---\n# Usar fila\n"),
                OKProposedItem(action: .update, type: .gotcha, path: gotchaPath, title: "G",
                               markdown: "---\ntitle: G\ndescription: d\ntype: gotcha\nproject: p5\n---\n# G novo\n",
                               baseHash: h("old gotcha\n"), baseContent: "old gotcha\n"),
            ]
        )
    }

    private func seed(_ p: MeetingProposal, in dir: URL) throws {
        try MeetingProposalStore.encode(p).write(to: dir.appendingPathComponent(MeetingProposal.fileName))
    }

    private func state(_ dir: URL) throws -> MeetingPipelineState {
        try JSONDecoder().decode(MeetingPipelineState.self, from: Data(contentsOf: dir.appendingPathComponent(MeetingPipelineState.stateFileName)))
    }

    private func journal(_ dir: URL) -> URL {
        dir.appendingPathComponent(MeetingProposalStore.journalFolder)
    }

    private func stagingEntries(_ vault: URL) -> [String] {
        (try? fm.contentsOfDirectory(atPath: vault.appendingPathComponent(".ok/local/voicetype-staging").path)) ?? []
    }

    private struct Meeting {
        var vault: URL
        var dir: URL
        var proposal: MeetingProposal
        var receipt: OKCommitReceipt
    }

    /// A meeting whose proposal, progress and `pipeline.json` are on disk,
    /// committed to the vault (item1 approved, item2 skipped)
    /// and not finalized: the journal is `committed`.
    private func committedMeeting() throws -> Meeting {
        let vault = try makeVault()
        let dir = try makeTemp()
        let meetingID = UUID()
        let p = try proposal(vault: vault, meetingID: meetingID)
        try seed(p, in: dir)
        try JSONEncoder().encode(MeetingPipelineState(noteID: meetingID, summarized: true, okProcessed: true))
            .write(to: dir.appendingPathComponent(MeetingPipelineState.stateFileName))
        var s = OKApprovalSession(proposal: p, progress: nil, timeZone: utc)
        s.approve()
        s.approve()
        s.approve()
        s.skip()
        try s.progress.save(in: dir)

        let identity = try OKVaultIdentity.of(vault)
        let writer = OKVaultWriter(vault: vault, identity: identity, journalDirectory: journal(dir))
        let result = try writer.commit(try s.commitOps(vault: vault, now: date), dependencies: s.commitDependencies(),
                                       receipt: s.receiptDraft(vault: identity), precondition: { true })
        guard case let .committed(receipt) = result else {
            Issue.record("commit: \(result)")
            throw CocoaError(.featureUnsupported)
        }
        #expect(MeetingProposalStore.hasJournal(dir))
        return Meeting(vault: vault, dir: dir, proposal: p, receipt: receipt)
    }

    private func remove(_ m: Meeting) {
        try? fm.removeItem(at: m.vault)
        try? fm.removeItem(at: m.dir)
    }

    private func expectFinalized(_ m: Meeting) throws {
        let s = try state(m.dir)
        #expect(s.okVault == m.receipt.vault)
        #expect(s.okProject == "p5")
        #expect(s.okRecordPath == m.proposal.paths?.record)
        #expect(s.okTranscriptPath == m.proposal.paths?.transcript)
        #expect(s.summarized && s.okProcessed == true)
        #expect(!fm.fileExists(atPath: m.dir.appendingPathComponent(MeetingProposal.fileName).path))
        #expect(!fm.fileExists(atPath: m.dir.appendingPathComponent(OKApprovalProgress.fileName).path))
        #expect(!fm.fileExists(atPath: journal(m.dir).path))
        #expect(stagingEntries(m.vault).isEmpty)
    }

    @Test func finalizeIsIdempotentFromEveryPartialState() throws {
        for done in 0...3 {
            let m = try committedMeeting()
            defer { remove(m) }
            if done >= 1 {
                var s = try state(m.dir)
                s.okVault = m.receipt.vault
                s.okProject = m.receipt.project
                s.okRecordPath = m.receipt.paths.record
                s.okTranscriptPath = m.receipt.paths.transcript
                try JSONEncoder().encode(s).write(to: m.dir.appendingPathComponent(MeetingPipelineState.stateFileName))
            }
            if done >= 2 { MeetingProposalStore.remove(m.dir) }
            if done >= 3 { try OKApprovalFinalizer.finalize(meetingDirectory: m.dir, receipt: m.receipt) }

            #expect(try OKApprovalFinalizer.finalize(meetingDirectory: m.dir, receipt: m.receipt).isEmpty)
            try expectFinalized(m)
            #expect(try OKApprovalFinalizer.finalize(meetingDirectory: m.dir, receipt: m.receipt).isEmpty)
            try expectFinalized(m)
            #expect(fm.fileExists(atPath: m.vault.appendingPathComponent(m.receipt.paths.record).path))
        }
    }

    @Test func finalizeWithoutPipelineStateCreatesIt() throws {
        let m = try committedMeeting()
        defer { remove(m) }
        try fm.removeItem(at: m.dir.appendingPathComponent(MeetingPipelineState.stateFileName))
        try OKApprovalFinalizer.finalize(meetingDirectory: m.dir, receipt: m.receipt)
        let s = try state(m.dir)
        #expect(s.noteID == m.receipt.meetingID)
        #expect(s.okRecordPath == m.receipt.paths.record)
        #expect(!fm.fileExists(atPath: journal(m.dir).path))
    }

    @Test func finalizeKeepsProposalOfNewerGeneration() throws {
        let m = try committedMeeting()
        defer { remove(m) }
        var p2 = m.proposal
        p2.generation = UUID()
        p2.items = []
        try seed(p2, in: m.dir)

        try OKApprovalFinalizer.finalize(meetingDirectory: m.dir, receipt: m.receipt)
        let s = try state(m.dir)
        #expect(s.okVault == m.receipt.vault)
        #expect(s.okRecordPath == m.receipt.paths.record)
        #expect(MeetingProposalStore.load(m.dir) == p2)
        #expect(!fm.fileExists(atPath: journal(m.dir).path))
    }

    @Test func finalizePartialKeepsOnlyConflictItemsPending() throws {
        let m = try committedMeeting()
        defer { remove(m) }
        let item2 = m.proposal.items[1]
        try put("atual\n", gotchaPath, in: m.vault)
        let conflicts = [OKConflict(itemID: item2.id, path: gotchaPath, currentContent: "atual\n", currentHash: h("atual\n"))]
        let paths = try #require(m.proposal.paths)

        try OKApprovalFinalizer.finalizePartial(meetingDirectory: m.dir, receipt: m.receipt, conflicts: conflicts)
        func check() throws {
            let s = try state(m.dir)
            #expect(s.okVault == m.receipt.vault)
            #expect(s.okRecordPath == paths.record)
            let p = try #require(MeetingProposalStore.load(m.dir))
            #expect(p.generation == m.proposal.generation)
            #expect(p.recordWritten)
            #expect(p.fixedPaths == paths)
            #expect(p.paths == paths)
            #expect(p.existingRecordHash == OKApprovalSession.hash(of: paths.record, in: m.vault))
            #expect(p.existingRecordHash != nil)
            #expect(p.existingTranscriptHash == OKApprovalSession.hash(of: paths.transcript, in: m.vault))
            var expected = item2
            expected.action = .update
            expected.baseHash = h("atual\n")
            expected.baseContent = "atual\n"
            expected.conflict = true
            #expect(p.items == [expected])
            let progress = try #require(OKApprovalProgress.load(m.dir))
            #expect(progress == OKApprovalProgress(generation: p.generation, project: "p5", stepIndex: 1))
            let session = OKApprovalSession(proposal: p, progress: progress, timeZone: utc)
            #expect(session.current == .item(item2.id))
            #expect(session.projectLocked)
            #expect(!fm.fileExists(atPath: journal(m.dir).path))
        }
        try check()
        try OKApprovalFinalizer.finalizePartial(meetingDirectory: m.dir, receipt: m.receipt, conflicts: conflicts)
        try check()
    }

    @Test func finalizePartialWithoutItemConflictsRemovesProposal() throws {
        let m = try committedMeeting()
        defer { remove(m) }
        try OKApprovalFinalizer.finalizePartial(meetingDirectory: m.dir, receipt: m.receipt,
                                                conflicts: [OKConflict(itemID: nil, path: "p5/index.md", currentContent: "x", currentHash: "hx")])
        try expectFinalized(m)
    }

    @Test func finalizePartialWithRecordConflictReturnsRecordToReview() throws {
        let m = try committedMeeting()
        defer { remove(m) }
        let paths = try #require(m.proposal.paths)
        try OKApprovalFinalizer.finalizePartial(meetingDirectory: m.dir, receipt: m.receipt,
                                                conflicts: [OKConflict(itemID: nil, path: paths.record, currentContent: "outro", currentHash: "ho")])
        let p = try #require(MeetingProposalStore.load(m.dir))
        #expect(!p.recordWritten)
        #expect(p.existingRecordHash == "ho")
        #expect(p.existingRecordContent == "outro")
        #expect(p.items.isEmpty)
        let session = OKApprovalSession(proposal: p, progress: OKApprovalProgress.load(m.dir), timeZone: utc)
        #expect(session.current == .record)
        #expect(session.previousMarkdown(for: .record) == "outro")
        #expect(!session.recordApproved)
    }
}
