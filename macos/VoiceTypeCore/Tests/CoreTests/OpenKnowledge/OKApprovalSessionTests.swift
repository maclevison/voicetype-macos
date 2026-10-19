import Foundation
import Testing
@testable import Core

@Suite("OKApprovalSession")
struct OKApprovalSessionTests {
    private let utc = TimeZone(identifier: "UTC")!
    // 2026-10-16 14:30:00 UTC
    private let date = Date(timeIntervalSince1970: 1_792_161_000)
    private let fm = FileManager.default
    private let item1ID = UUID()
    private let item2ID = UUID()

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

    /// A vault with `.ok/`, a README listing p5, and p5 with an index and a gotcha.
    private func makeVault() throws -> URL {
        let vault = try makeTemp()
        try fm.createDirectory(at: vault.appendingPathComponent(".ok"), withIntermediateDirectories: true)
        try put("# Vault\n\n## Projetos\n\n- [p5 — Projeto p5](./p5/index.md)\n", "README.md", in: vault)
        try put("---\ntitle: p5\ndescription: Projeto p5.\ntype: indice\nproject: p5\n---\n# p5\n\n## Conhecimento registrado\n\n### Arquitetura\n\n- [A](./arquitetura/a.md)\n",
                "p5/index.md", in: vault)
        try put("old gotcha\n", "p5/gotchas/g.md", in: vault)
        return vault
    }

    private func note(title: String = "Sprint review", id: UUID = UUID(), transcript: String? = "Você: oi\nOutros: olá") -> MeetingNote {
        MeetingNote(id: id, startedAt: date, duration: 30 * 60, platform: "teams",
                    summary: MeetingSummary(title: title, summary: "Revisamos a sprint."), transcript: transcript)
    }

    private func source(_ itemPath: String, _ paths: OKMeetingPaths) -> String {
        "\n## Fontes\n\n- [Reunião](\(OKPath.relativeLink(from: itemPath, to: paths.record)))\n"
    }

    /// Two items: a new decision and an update of `gotchas/g.md`.
    private func items(project: String, paths: OKMeetingPaths) -> [OKProposedItem] {
        let decision = "\(project)/decisoes/usar-fila.md"
        let gotcha = "\(project)/gotchas/g.md"
        return [
            OKProposedItem(id: item1ID, action: .new, type: .decisao, path: decision, title: "Usar fila",
                           markdown: "---\ntitle: Usar fila\ndescription: d\ntype: decisao\nproject: \(project)\n---\n# Usar fila\n" + source(decision, paths)),
            OKProposedItem(id: item2ID, action: .update, type: .gotcha, path: gotcha, title: "G",
                           markdown: "---\ntitle: G\ndescription: d\ntype: gotcha\nproject: \(project)\n---\n# G novo\n" + source(gotcha, paths),
                           baseHash: h("old gotcha\n"), baseContent: "old gotcha\n"),
        ]
    }

    private func proposal(vault: URL?, project: String = "p5", title: String = "Sprint review", withItems: Bool = true) -> MeetingProposal {
        let paths = OKMeetingPaths.make(project: project, startedAt: date, title: title, timeZone: utc)
        return MeetingProposal(
            meetingID: UUID(), note: note(title: title), vault: vault.flatMap { try? OKVaultIdentity.of($0) },
            suggestedProject: project, project: project, paths: paths,
            items: withItems ? items(project: project, paths: paths) : []
        )
    }

    private func session(_ p: MeetingProposal, progress: OKApprovalProgress? = nil) -> OKApprovalSession {
        OKApprovalSession(proposal: p, progress: progress, timeZone: utc)
    }

    /// Writes `p` as the proposal on disk (first write, no generation check).
    private func seed(_ p: MeetingProposal, in dir: URL) throws {
        try MeetingProposalStore.encode(p).write(to: dir.appendingPathComponent(MeetingProposal.fileName))
    }

    // MARK: - Steps

    @Test func recordCannotBeSkippedAndGatesItems() {
        var s = session(proposal(vault: nil))
        #expect(s.steps == [.project, .record, .item(item1ID), .item(item2ID)])
        #expect(s.current == .project)
        s.approve()
        #expect(s.current == .record)
        s.skip()
        #expect(s.current == .record)
        #expect(!s.recordApproved)
        s.approve()
        #expect(s.current == .item(item1ID))
    }

    @Test func projectStepNeedsAProject() {
        var p = proposal(vault: nil)
        p.project = nil
        p.suggestedProject = nil
        var s = session(p)
        s.approve()
        #expect(s.current == .project)
    }

    @Test func navigationApproveSkipBack() {
        var s = session(proposal(vault: nil))
        s.approve()
        s.approve()
        s.approve()
        #expect(!s.canCommit)
        s.skip()
        #expect(s.canCommit)
        #expect(s.isFinished)
        s.back()
        #expect(s.current == .item(item2ID))
        #expect(!s.isFinished)
        #expect(s.isApproved(item1ID))
        #expect(s.progress.decisions[item2ID] == .skipped)
        #expect(s.canCommit)
        s.back()
        #expect(s.current == .item(item1ID))
    }

    @Test func editsAndUndo() {
        var s = session(proposal(vault: nil))
        let generated = s.proposal.items[0].markdown
        s.approve()
        s.approve()
        s.edit("x")
        #expect(s.markdown(for: .item(item1ID)) == "x")
        #expect(s.progress.hasEdits)
        s.undoEdits()
        #expect(s.markdown(for: .item(item1ID)) == generated)
        #expect(!s.progress.hasEdits)
    }

    @Test func editAfterApprovalInvalidatesStamp() {
        var s = session(proposal(vault: nil))
        s.approve()
        s.approve()
        #expect(s.recordApproved)
        s.approve()
        #expect(s.isApproved(item1ID))
        s.back()
        s.edit("x")
        #expect(!s.isApproved(item1ID))
        s.approve()
        #expect(s.isApproved(item1ID))

        s.back()
        s.back()
        #expect(s.current == .record)
        s.edit("registro editado")
        #expect(!s.recordApproved)
    }

    // MARK: - Project

    @Test func changingProjectRequiresRedistill() throws {
        var s = session(proposal(vault: nil))
        #expect(s.chosenProject == "p5")
        #expect(!s.needsRedistill)
        try s.chooseProject("acme")
        #expect(s.chosenProject == "acme")
        #expect(s.needsRedistill)
        #expect(!s.canCommit)

        var fixed = proposal(vault: nil)
        fixed.fixedPaths = fixed.paths
        var locked = session(fixed)
        #expect(locked.projectLocked)
        #expect(throws: OKApprovalSession.ProjectError.projectLocked) { try locked.chooseProject("acme") }
        #expect(throws: OKApprovalSession.ProjectError.projectLocked) {
            try locked.chooseNewProject(slug: "acme", description: "Acme", existing: [])
        }
        #expect(locked.chosenProject == "p5")
    }

    @Test func newProjectValidation() throws {
        var s = session(proposal(vault: nil))
        let existing = [OKProject(slug: "p5", title: "p5", description: "")]
        #expect(throws: OKApprovalSession.ProjectError.invalidSlug) {
            try s.chooseNewProject(slug: "Meu Projeto", description: "Acme", existing: existing)
        }
        #expect(throws: OKApprovalSession.ProjectError.alreadyExists) {
            try s.chooseNewProject(slug: "p5", description: "Acme", existing: existing)
        }
        #expect(throws: OKApprovalSession.ProjectError.emptyDescription) {
            try s.chooseNewProject(slug: "acme", description: "  ", existing: existing)
        }
        #expect(s.chosenProject == "p5")
        try s.chooseNewProject(slug: "acme", description: " Projeto Acme ", existing: existing)
        #expect(s.chosenProject == "acme")
        #expect(s.progress.newProject == OKNewProject(slug: "acme", description: "Projeto Acme"))
        try s.chooseProject("p5")
        #expect(s.progress.newProject == nil)
    }

    // MARK: - Commit ops

    @Test func commitOpsForNewProject() throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        let readme = try String(contentsOf: vault.appendingPathComponent("README.md"), encoding: .utf8)
        var s = session(proposal(vault: vault, project: "acme"))
        try s.chooseNewProject(slug: "acme", description: "Projeto Acme", existing: try OKVaultCatalog.projects(in: vault))
        s.approve()
        s.approve()
        s.approve()
        s.skip()
        let paths = try #require(s.paths)

        let ops = try s.commitOps(vault: vault, now: date)
        let metadata = ops.filter { if case .createIfMissing = $0 { true } else { false } }
        #expect(metadata.count == 9)
        #expect(metadata.allSatisfy { $0.path.hasPrefix("acme/") && $0.path.hasSuffix("/.ok/frontmatter.yml") })
        let index = try #require(ops.first { $0.path == "acme/index.md" })
        guard case let .create(_, indexContent, nil) = index else { Issue.record("index: \(index)"); return }
        #expect(indexContent.contains("- [Usar fila](./decisoes/usar-fila.md)"))
        #expect(!indexContent.contains("g.md"))
        #expect(ops.contains(.update(path: "README.md",
                                     content: OKProjectScaffold.readmeAddingProject(readme, project: "acme", description: "Projeto Acme"),
                                     expectedHash: h(readme), itemID: nil)))
        let transcript = try #require(ops.first { $0.path == paths.transcript })
        guard case .create = transcript else { Issue.record("transcript: \(transcript)"); return }
        let record = try #require(ops.first { $0.path == paths.record })
        guard case let .create(_, recordContent, nil) = record else { Issue.record("record: \(record)"); return }
        #expect(recordContent.contains(OKMeetingRenderer.distilledHeading))
        #expect(recordContent.contains("[Usar fila](../decisoes/usar-fila.md)"))
        #expect(!recordContent.contains("g.md"))
        #expect(ops.contains(.create(path: "acme/decisoes/usar-fila.md", content: s.markdown(for: .item(item1ID)), itemID: item1ID)))
        #expect(!ops.contains { $0.path == "acme/gotchas/g.md" })
    }

    @Test func commitOpsForExistingProjectLinksOnlyNewItemsInIndex() throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        let index = try String(contentsOf: vault.appendingPathComponent("p5/index.md"), encoding: .utf8)
        var s = session(proposal(vault: vault))
        s.approve()
        s.approve()
        s.approve()
        s.approve()
        let paths = try #require(s.paths)

        let ops = try s.commitOps(vault: vault, now: date)
        let metadata = ops.compactMap { op -> String? in if case let .createIfMissing(path, _) = op { path } else { nil } }
        #expect(metadata == ["p5/reunioes/.ok/frontmatter.yml", "p5/reunioes/transcricoes/.ok/frontmatter.yml"])
        let indexOp = try #require(ops.first { $0.path == "p5/index.md" })
        guard case let .update(_, indexContent, expected, nil) = indexOp else { Issue.record("index: \(indexOp)"); return }
        #expect(expected == h(index))
        #expect(indexContent.contains("- [Usar fila](./decisoes/usar-fila.md)"))
        #expect(!indexContent.contains("gotchas/g.md"))
        let record = try #require(ops.first { $0.path == paths.record })
        guard case let .create(_, recordContent, _) = record else { Issue.record("record: \(record)"); return }
        #expect(recordContent.contains("[Usar fila](../decisoes/usar-fila.md)"))
        #expect(recordContent.contains("[G](../gotchas/g.md)"))
        #expect(ops.contains(.update(path: "p5/gotchas/g.md", content: s.markdown(for: .item(item2ID)),
                                     expectedHash: h("old gotcha\n"), itemID: item2ID)))
        #expect(ops.last?.path == "p5/index.md")
    }

    @Test func reapprovalReusesFixedPathsWithUpdateOps() throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        var p = proposal(vault: vault, title: "Novo título", withItems: false)
        let fixed = OKMeetingPaths.make(project: "p5", startedAt: date, title: "Sprint review", timeZone: utc)
        p.fixedPaths = fixed
        p.paths = fixed
        p.existingRecordHash = "hr"
        p.existingTranscriptHash = "ht"
        var s = session(p)
        s.approve()
        s.approve()

        let ops = try s.commitOps(vault: vault, now: date)
        #expect(ops.map(\.path) == ["p5/reunioes/.ok/frontmatter.yml", "p5/reunioes/transcricoes/.ok/frontmatter.yml", fixed.transcript, fixed.record])
        guard case let .update(_, transcript, "ht", nil) = ops[2], case let .update(_, record, "hr", nil) = ops[3] else {
            Issue.record("ops: \(ops)")
            return
        }
        #expect(record.contains("title: \"Novo título\""))
        #expect(transcript.contains("Novo título — transcrição"))
    }

    @Test func commitOpsRefuseEditsWithInvalidFrontmatter() throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        let p = proposal(vault: vault)
        var s = session(p)
        s.approve()
        s.approve()
        let item = s.markdown(for: .item(item1ID))
        s.edit(item.replacingOccurrences(of: "title: Usar fila", with: "title: Usar fila: agora"))
        s.approve()
        s.approve()
        #expect(s.canCommit)
        #expect(throws: OKApprovalSession.CommitError.invalidFrontmatter(p.items[0].path)) { try s.commitOps(vault: vault, now: date) }
        #expect(OKApprovalSession.CommitError.invalidFrontmatter(p.items[0].path).localizedDescription.contains(p.items[0].path))

        s.back()
        s.back()
        s.edit(item.replacingOccurrences(of: "title: Usar fila", with: "title: \"Usar fila: agora\""))
        s.approve()
        s.approve()
        #expect(try s.commitOps(vault: vault, now: date).contains { $0.path == p.items[0].path })

        // The record too: its edit is what the vault gets.
        var r = session(p)
        r.approve()
        r.edit(r.markdown(for: .record).replacingOccurrences(of: "type: reuniao", with: "type: [reuniao"))
        r.approve()
        r.approve()
        r.approve()
        let record = try #require(p.paths?.record)
        #expect(throws: OKApprovalSession.CommitError.invalidFrontmatter(record)) { try r.commitOps(vault: vault, now: date) }
    }

    @Test func commitOpsRefuseAnotherVault() throws {
        let a = try makeVault()
        let b = try makeVault()
        defer {
            try? fm.removeItem(at: a)
            try? fm.removeItem(at: b)
        }
        var s = session(proposal(vault: a, withItems: false))
        s.approve()
        s.approve()
        #expect(throws: OKApprovalSession.CommitError.vaultMismatch) { try s.commitOps(vault: b, now: date) }
        #expect(try s.commitOps(vault: a, now: date).isEmpty == false)

        var noPaths = proposal(vault: a, withItems: false)
        noPaths.paths = nil
        #expect(throws: OKApprovalSession.CommitError.noPaths) { try session(noPaths).commitOps(vault: a, now: date) }
        #expect(throws: OKApprovalSession.CommitError.notReady) { try session(proposal(vault: a)).commitOps(vault: a, now: date) }
    }

    @Test func commitOpsUsePersistedPathsNotRecomputed() throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        var p = proposal(vault: vault, title: "Daily", withItems: false)
        p.paths = OKMeetingPaths(record: "p5/reunioes/2026-10-16-daily-2.md", transcript: "p5/reunioes/transcricoes/2026-10-16-daily-2.md")
        var s = session(p)
        s.approve()
        s.approve()
        let moved1 = s.relocateIfTaken(vault: vault)
        #expect(!moved1)

        let ops = try s.commitOps(vault: vault, now: date)
        #expect(ops.contains { $0.path == "p5/reunioes/2026-10-16-daily-2.md" })
        #expect(ops.contains { $0.path == "p5/reunioes/transcricoes/2026-10-16-daily-2.md" })
        #expect(!ops.contains { $0.path.hasSuffix("-daily.md") })
        #expect(s.receiptDraft(vault: try OKVaultIdentity.of(vault)).paths == p.paths)
    }

    // MARK: - Conflicts

    @Test func conflictReturnsItemToReviewWithCurrentContent() throws {
        var s = session(proposal(vault: nil))
        s.approve()
        s.approve()
        s.approve()
        s.approve()
        #expect(s.canCommit)
        let path = s.proposal.items[0].path

        s.applyConflicts([OKConflict(itemID: item1ID, path: path, currentContent: "novo atual", currentHash: "h2")])
        #expect(s.current == .item(item1ID))
        #expect(s.progress.decisions[item1ID] == nil)
        let item = try #require(s.proposal.items.first { $0.id == item1ID })
        #expect(item.conflict)
        #expect(item.baseHash == "h2")
        #expect(item.action == .update)
        #expect(s.previousMarkdown(for: .item(item1ID)) == "novo atual")
        #expect(s.recordApproved)
        #expect(s.isApproved(item2ID))
        #expect(!s.canCommit)
    }

    @Test func indexConflictChangesNothing() {
        var s = session(proposal(vault: nil))
        s.approve()
        s.approve()
        s.approve()
        s.approve()
        let before = s
        s.applyConflicts([OKConflict(itemID: nil, path: "p5/index.md", currentContent: "x", currentHash: "hx")])
        #expect(s == before)
    }

    @Test func recordWrittenProposalCommitsOnlyItems() throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        var p = proposal(vault: vault)
        p.recordWritten = true
        p.fixedPaths = p.paths
        p.items = [p.items[1]]
        p.items[0].conflict = true
        var s = session(p)
        let paths = try #require(s.paths)
        #expect(s.steps == [.project, .item(item2ID)])
        #expect(s.recordApproved)
        s.approve()
        s.approve()
        #expect(s.canCommit)

        let ops = try s.commitOps(vault: vault, now: date)
        #expect(ops == [.update(path: "p5/gotchas/g.md", content: s.markdown(for: .item(item2ID)), expectedHash: h("old gotcha\n"), itemID: item2ID)])
        #expect(s.commitDependencies() == [paths.record, paths.transcript])
        #expect(session(proposal(vault: vault)).commitDependencies() == [])
    }

    @Test func missingDependencyReturnsRecordToReview() throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        var p = proposal(vault: vault)
        p.recordWritten = true
        p.fixedPaths = p.paths
        p.existingRecordHash = "hr"
        p.existingTranscriptHash = "ht"
        var s = session(p)
        let paths = try #require(s.paths)
        s.approve()
        s.approve()
        s.approve()
        #expect(s.canCommit)

        s.applyConflicts([OKConflict(itemID: nil, path: paths.record, currentContent: nil, currentHash: nil)])
        #expect(!s.proposal.recordWritten)
        #expect(s.proposal.existingRecordHash == nil)
        #expect(s.proposal.existingTranscriptHash == "ht")
        #expect(s.current == .record)
        #expect(!s.canCommit)
        #expect(s.commitDependencies() == [])
        s.approve()
        #expect(s.canCommit)

        let ops = try s.commitOps(vault: vault, now: date)
        guard let record = ops.first(where: { $0.path == paths.record }), case .create = record else {
            Issue.record("ops: \(ops)")
            return
        }
        guard let transcript = ops.first(where: { $0.path == paths.transcript }), case .update(_, _, "ht", nil) = transcript else {
            Issue.record("ops: \(ops)")
            return
        }
        #expect(ops.contains { $0.path == "p5/decisoes/usar-fila.md" })
        #expect(ops.contains { $0.path == "p5/gotchas/g.md" })
    }

    // MARK: - Relocation

    @Test func relocateRewritesSourceLinksAndRequiresReapproval() throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        let first = proposal(vault: vault, title: "Daily", withItems: false)
        let paths = try #require(first.paths)
        #expect(paths.record == "p5/reunioes/2026-10-16-daily.md")
        try put(OKMeetingRenderer.renderRecord(first.note, project: "p5", paths: paths, timeZone: utc), paths.record, in: vault)

        var second = proposal(vault: vault, title: "Daily")
        second.items = [second.items[0]]
        var s = session(second)
        s.approve()
        s.approve()
        s.approve()
        #expect(s.canCommit)

        let moved2 = s.relocateIfTaken(vault: vault)
        #expect(moved2)
        #expect(s.paths?.record == "p5/reunioes/2026-10-16-daily-2.md")
        #expect(s.paths?.transcript == "p5/reunioes/transcricoes/2026-10-16-daily-2.md")
        let adr = s.markdown(for: .item(item1ID))
        #expect(adr.contains("](../reunioes/2026-10-16-daily-2.md)"))
        #expect(!adr.contains("2026-10-16-daily.md)"))
        #expect(s.progress.decisions[item1ID] == nil)
        #expect(!s.recordApproved)
        #expect(s.current == .record)
        let moved3 = s.relocateIfTaken(vault: vault)
        #expect(!moved3)

        s.approve()
        s.approve()
        let ops = try s.commitOps(vault: vault, now: date)
        guard let record = ops.first(where: { $0.path == "p5/reunioes/2026-10-16-daily-2.md" }), case let .create(_, content, nil) = record else {
            Issue.record("ops: \(ops)")
            return
        }
        #expect(content.contains("transcricoes/2026-10-16-daily-2.md"))
        #expect(ops.contains(.create(path: "p5/decisoes/usar-fila.md", content: adr, itemID: item1ID)))
        #expect(!ops.contains { $0.path == paths.record })
    }

    @Test func relocateRewritesEditsAndFlagsItemsStillCitingTheOldRecord() throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        let first = proposal(vault: vault, title: "Daily", withItems: false)
        let paths = try #require(first.paths)
        try put(OKMeetingRenderer.renderRecord(first.note, project: "p5", paths: paths, timeZone: utc), paths.record, in: vault)

        var s = session(proposal(vault: vault, title: "Daily"))
        s.approve()
        s.edit(s.markdown(for: .record) + "\nNota: ver transcricoes/2026-10-16-daily.md\n")
        s.approve()
        s.edit("fonte em p5/reunioes/2026-10-16-daily.md, outro formato")
        s.approve()
        s.skip()

        let moved4 = s.relocateIfTaken(vault: vault)
        #expect(moved4)
        #expect(s.progress.recordEdit?.contains("transcricoes/2026-10-16-daily-2.md") == true)
        #expect(s.progress.recordEdit?.contains("transcricoes/2026-10-16-daily.md") == false)
        // The edited item has no link to rewrite and still names the old record.
        #expect(s.markdown(for: .item(item1ID)) == "fonte em p5/reunioes/2026-10-16-daily.md, outro formato")
        #expect(s.progress.decisions[item1ID] == nil)
        // The skipped gotcha's source link changed, so its decision is gone too.
        #expect(s.progress.decisions[item2ID] == nil)
    }

    @Test func relocateNeverMovesOwnOrFixedPaths() throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        let p = proposal(vault: vault, title: "Daily")
        let paths = try #require(p.paths)
        // An earlier write of this same meeting.
        try put(OKMeetingRenderer.renderRecord(p.note, project: "p5", paths: paths, timeZone: utc), paths.record, in: vault)
        var own = session(p)
        let moved5 = own.relocateIfTaken(vault: vault)
        #expect(!moved5)

        try put("---\nid: \(UUID().uuidString)\n---\n", paths.record, in: vault)
        var fixed = p
        fixed.fixedPaths = paths
        var locked = session(fixed)
        let moved6 = locked.relocateIfTaken(vault: vault)
        #expect(!moved6)
        #expect(locked.paths == paths)
    }

    @Test func relocateKeepsCitationsOfTheOtherMeeting() throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        let first = proposal(vault: vault, title: "Daily", withItems: false)
        let paths = try #require(first.paths)
        try put(OKMeetingRenderer.renderRecord(first.note, project: "p5", paths: paths, timeZone: utc), paths.record, in: vault)

        var p = proposal(vault: vault, title: "Daily")
        // The gotcha already cited the first Daily before this meeting.
        let base = "old\n\n## Fontes\n\n- [Daily](../reunioes/2026-10-16-daily.md)\n"
        p.items[1].baseContent = base
        p.items[1].baseHash = h(base)
        p.items[1].markdown = base + "- [Daily de novo](../reunioes/2026-10-16-daily.md)\n"
        var s = session(p)
        s.approve()
        s.approve()
        s.approve()
        s.approve()

        let moved = s.relocateIfTaken(vault: vault)
        #expect(moved)
        #expect(s.markdown(for: .item(item2ID)) == p.items[1].markdown)
        #expect(s.progress.decisions[item2ID] == nil)
        #expect(s.markdown(for: .item(item1ID)).contains("](../reunioes/2026-10-16-daily-2.md)"))
    }

    // MARK: - Redistillation

    @Test func redistillToAFreeNameRetargetsCarriedEdits() async throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        var p = proposal(vault: vault, title: "Daily")
        p.items = [p.items[0]]
        var s = session(p)
        s.approve()
        s.edit(s.markdown(for: .record) + "\nObs. do usuário.\n")
        #expect(s.markdown(for: .record).contains("transcricoes/2026-10-16-daily.md"))
        s.approve()
        s.edit(s.markdown(for: .item(item1ID)) + "\nNota do usuário.\n")
        s.approve()
        #expect(s.canCommit)

        // The first Daily is written, and the catalog changed: redistilling
        // moves this meeting to the next free name.
        let first = proposal(vault: vault, title: "Daily", withItems: false)
        try put(OKMeetingRenderer.renderRecord(first.note, project: "p5", paths: try #require(first.paths), timeZone: utc),
                "p5/reunioes/2026-10-16-daily.md", in: vault)
        try put("---\ntitle: Outro\n---\n", "p5/decisoes/outro.md", in: vault)
        let fake = FakeAssistant(plan: [OKPlannedItem(action: .new, type: .decisao, path: "p5/decisoes/usar-fila.md", title: "Usar fila", reason: "r")])
        let q = try await OKProposalBuilder(assistant: fake, user: "Mac", timeZone: utc).redistill(s.proposal, project: "p5", vault: vault, now: date)
        #expect(q.paths?.record == "p5/reunioes/2026-10-16-daily-2.md")

        let pending = s.replaceProposal(q)
        let adr = q.items[0].id
        #expect(pending == [adr])
        let record = s.markdown(for: .record)
        #expect(record.contains("transcricoes/2026-10-16-daily-2.md"))
        #expect(!record.contains("2026-10-16-daily.md"))
        #expect(record.contains("Obs. do usuário."))
        #expect(!s.recordApproved)
        let edited = s.markdown(for: .item(adr))
        #expect(edited.contains("](../reunioes/2026-10-16-daily-2.md)"))
        #expect(!edited.contains("2026-10-16-daily.md"))
        #expect(edited.contains("Nota do usuário."))
        #expect(!s.isApproved(adr))
        #expect(s.current == .record)
        let moved = s.relocateIfTaken(vault: vault)
        #expect(!moved)

        s.approve()
        s.approve()
        let ops = try s.commitOps(vault: vault, now: date)
        #expect(!ops.contains { $0.path.hasSuffix("2026-10-16-daily.md") })
        guard let recordOp = ops.first(where: { $0.path == "p5/reunioes/2026-10-16-daily-2.md" }), case let .create(_, content, nil) = recordOp else {
            Issue.record("ops: \(ops)")
            return
        }
        #expect(!content.contains("2026-10-16-daily.md"))
        #expect(ops.contains(.create(path: "p5/decisoes/usar-fila.md", content: edited, itemID: adr)))
    }

    @Test func projectChangeRetargetsEditedRecord() throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        var s = session(proposal(vault: vault, withItems: false))
        s.approve()
        s.edit(s.markdown(for: .record) + "\nObs. do usuário.\n")
        s.approve()
        #expect(s.canCommit)

        try s.chooseProject("acme")
        #expect(!s.canCommit)
        s.replaceProposal(OKProposalBuilder.repath(s.proposal, project: "acme", vault: vault, timeZone: utc))
        #expect(!s.needsRedistill)
        let record = s.markdown(for: .record)
        #expect(OKFrontmatter.scalar("project", in: record) == "acme")
        #expect(OKFrontmatter.scalar("tags", in: record) == "[reuniao, acme]")
        #expect(record.contains("Obs. do usuário."))
        #expect(!s.recordApproved)
        #expect(s.current == .record)

        s.approve()
        let ops = try s.commitOps(vault: vault, now: date)
        let paths = try #require(s.paths)
        #expect(paths.record.hasPrefix("acme/reunioes/"))
        guard let recordOp = ops.first(where: { $0.path == paths.record }), case let .create(_, content, nil) = recordOp else {
            Issue.record("ops: \(ops)")
            return
        }
        #expect(content.contains("project: acme"))
        #expect(!content.contains("p5"))
    }

    @Test func recordApprovalIsBoundToVaultVersions() {
        let p = proposal(vault: nil, withItems: false)
        var s = session(p)
        s.approve()
        s.approve()
        #expect(s.recordApproved)

        var q = p
        q.existingTranscriptHash = "outra"
        s.replaceProposal(q)
        #expect(s.markdown(for: .record) == session(p).markdown(for: .record))
        #expect(!s.recordApproved)
        #expect(s.current == .record)
    }

    @Test func recordConflictSurvivesSaveAndReopen() throws {
        let vault = try makeVault()
        let dir = try makeTemp()
        defer {
            try? fm.removeItem(at: vault)
            try? fm.removeItem(at: dir)
        }
        let p = proposal(vault: vault, withItems: false)
        try seed(p, in: dir)
        var s = session(p)
        s.approve()
        s.approve()
        let paths = try #require(s.paths)
        s.applyConflicts([OKConflict(itemID: nil, path: paths.record, currentContent: "outro", currentHash: h("outro"))])
        try MeetingProposalStore.save(s.proposal, in: dir)
        try s.progress.save(in: dir)

        var reopened = session(try #require(MeetingProposalStore.load(dir)), progress: OKApprovalProgress.load(dir))
        #expect(reopened.previousMarkdown(for: .record) == "outro")
        #expect(!reopened.recordApproved)
        #expect(reopened.current == .record)
        reopened.approve()
        #expect(reopened.recordApproved)
        let ops = try reopened.commitOps(vault: vault, now: date)
        guard let recordOp = ops.first(where: { $0.path == paths.record }), case .update(_, _, h("outro"), nil) = recordOp else {
            Issue.record("ops: \(ops)")
            return
        }

        // The record changed again: the approval no longer holds.
        reopened.applyConflicts([OKConflict(itemID: nil, path: paths.record, currentContent: "terceiro", currentHash: h("terceiro"))])
        #expect(reopened.previousMarkdown(for: .record) == "terceiro")
        #expect(!reopened.recordApproved)
    }


    @Test func replaceProposalKeepsDecisionsOfUnchangedItems() {
        let p = proposal(vault: nil)
        var s = session(p)
        s.approve()
        s.approve()
        s.edit("x")
        s.approve()
        s.approve()
        #expect(s.canCommit)

        var q = p
        q.items = [
            OKProposedItem(action: .new, type: .decisao, path: p.items[0].path, title: "Usar fila", markdown: p.items[0].markdown),
            OKProposedItem(action: .update, type: .gotcha, path: p.items[1].path, title: "G", markdown: "outro texto",
                           baseHash: p.items[1].baseHash, baseContent: p.items[1].baseContent),
        ]
        let pending = s.replaceProposal(q)
        #expect(pending == [q.items[1].id])
        #expect(s.isApproved(q.items[0].id))
        #expect(s.markdown(for: .item(q.items[0].id)) == "x")
        #expect(!s.isApproved(q.items[1].id))
        #expect(s.current == .item(q.items[1].id))
        #expect(s.progress.decisions[item1ID] == nil)
        #expect(s.progress.edits[item1ID] == nil)
    }

    @Test func approvalIsBoundToBaseRevision() throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        var p = proposal(vault: vault)
        p.items = [p.items[1]]
        var s = session(p)
        s.approve()
        s.approve()
        s.approve()
        #expect(s.progress.decisions[item2ID] == .approved(contentHash: h(p.items[0].markdown), baseHash: h("old gotcha\n")))
        #expect(s.canCommit)

        let id = UUID()
        var q = p
        q.items = [OKProposedItem(id: id, action: .update, type: .gotcha, path: p.items[0].path, title: "G",
                                  markdown: p.items[0].markdown, baseHash: "hC", baseContent: "C")]
        #expect(s.replaceProposal(q) == [id])
        #expect(!s.isApproved(id))
        #expect(!s.canCommit)
        #expect(s.current == .item(id))
        #expect(s.previousMarkdown(for: .item(id)) == "C")
        #expect(throws: OKApprovalSession.CommitError.notReady) { try s.commitOps(vault: vault, now: date) }

        s.approve()
        #expect(s.progress.decisions[id] == .approved(contentHash: h(p.items[0].markdown), baseHash: "hC"))
        let ops = try s.commitOps(vault: vault, now: date)
        #expect(ops.contains(.update(path: p.items[0].path, content: p.items[0].markdown, expectedHash: "hC", itemID: id)))
    }

    // MARK: - Progress

    @Test func progressRoundTrip() throws {
        let dir = try makeTemp()
        defer { try? fm.removeItem(at: dir) }
        let p = proposal(vault: nil)
        try seed(p, in: dir)
        let progress = OKApprovalProgress(
            generation: p.generation, project: "acme", newProject: OKNewProject(slug: "acme", description: "Acme"),
            stepIndex: 2, recordApproval: "hr", recordEdit: "registro",
            decisions: [item1ID: .approved(contentHash: "c", baseHash: nil), item2ID: .skipped], edits: [item1ID: "x"]
        )
        try progress.save(in: dir)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("ok-progress.json").path))
        #expect(OKApprovalProgress.load(dir) == progress)
        #expect(progress.hasEdits)
        #expect(!OKApprovalProgress(generation: p.generation).hasEdits)
    }

    @Test func progressOfOtherGenerationIsIgnored() throws {
        let dir = try makeTemp()
        defer { try? fm.removeItem(at: dir) }
        let p1 = proposal(vault: nil)
        var s1 = session(p1)
        s1.approve()
        s1.approve()
        s1.edit("x")
        s1.approve()
        let old = s1.progress
        #expect(old.recordApproval != nil)

        var p2 = p1
        p2.generation = UUID()
        let s2 = session(p2, progress: old)
        #expect(s2.current == .project)
        #expect(!s2.recordApproved)
        #expect(s2.progress == OKApprovalProgress(generation: p2.generation, project: "p5"))

        try seed(p1, in: dir)
        try old.save(in: dir)
        let saved = try Data(contentsOf: dir.appendingPathComponent(OKApprovalProgress.fileName))
        try seed(p2, in: dir)
        var stale = old
        stale.stepIndex = 0
        #expect(throws: MeetingProposalStore.StoreError.generationChanged) { try stale.save(in: dir) }
        #expect(try Data(contentsOf: dir.appendingPathComponent(OKApprovalProgress.fileName)) == saved)
    }
}
