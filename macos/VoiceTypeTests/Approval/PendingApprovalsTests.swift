import Core
import UserNotifications
import XCTest
@testable import VoiceType

private let gotchaPath = "p5/gotchas/g.md"
private let decisionPath = "p5/decisoes/usar-fila.md"
private let newGotcha = "---\ntitle: G\ndescription: d\ntype: gotcha\nproject: p5\n---\n# G novo\n"

private func put(_ text: String, _ relPath: String, in root: URL) throws {
    let url = root.appendingPathComponent(relPath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func text(_ relPath: String, in root: URL) -> String? {
    (try? Data(contentsOf: root.appendingPathComponent(relPath))).map { String(decoding: $0, as: UTF8.self) }
}

/// Replaces the content through a descriptor someone kept open.
private func writeThrough(_ editor: FileHandle, _ content: String) throws {
    try editor.truncate(atOffset: 0)
    try editor.write(contentsOf: Data(content.utf8))
    try editor.synchronize()
}

/// The meeting record's op (`p5/reunioes/<date>-<slug>.md`).
private func recordIndex(_ ops: [OKVaultOp]) -> Int {
    ops.firstIndex { $0.path.hasPrefix("p5/reunioes/") && !$0.path.contains("/transcricoes/") && $0.path.hasSuffix(".md") }!
}

/// Every meeting here is committed for real by `OKVaultWriter` and killed at
/// a fault point (`OKSimulatedCrash`), so `bootstrap()` sees the same disk a
/// crash would leave.
@MainActor
final class PendingApprovalsTests: XCTestCase {
    private struct Boom: Error {}

    private let utc = TimeZone(identifier: "UTC")!
    // 2026-10-16 14:30:00 UTC
    private let date = Date(timeIntervalSince1970: 1_792_161_000)
    private let fm = FileManager.default
    private var cleanup: [URL] = []
    private var notices: [(title: String, body: String)] = []

    // MARK: - Fixtures

    private func removeTemps() {
        for url in cleanup { try? fm.removeItem(at: url) }
        cleanup = []
    }

    private func makeTemp() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        cleanup.append(url)
        return url
    }

    private func makeVault() throws -> URL {
        let vault = try makeTemp()
        try fm.createDirectory(at: vault.appendingPathComponent(".ok"), withIntermediateDirectories: true)
        try put("---\ntitle: p5\ndescription: Projeto p5.\ntype: indice\nproject: p5\n---\n# p5\n", "p5/index.md", in: vault)
        try put("old gotcha\n", gotchaPath, in: vault)
        return vault
    }

    /// Files outside the vault's own `.ok/`, by vault-relative path.
    private func snapshot(_ vault: URL) -> [String: String] {
        var files: [String: String] = [:]
        let root = vault.resolvingSymlinksInPath().path
        let walker = fm.enumerator(at: vault, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walker?.nextObject() as? URL {
            if url.resolvingSymlinksInPath().path == root + "/.ok" { walker?.skipDescendants(); continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = String(url.resolvingSymlinksInPath().path.dropFirst(root.count + 1))
            files[path] = text(path, in: vault)
        }
        return files
    }

    /// Relative `.md` links (outside `.ok/`) whose target doesn't exist.
    private func brokenLinks(_ vault: URL) -> [String] {
        let link = try! NSRegularExpression(pattern: #"\]\(([^)\s]+\.md)\)"#)
        return snapshot(vault).sorted { $0.key < $1.key }.flatMap { path, content -> [String] in
            let dir = (path as NSString).deletingLastPathComponent
            return link.matches(in: content, range: NSRange(content.startIndex..., in: content)).compactMap { match in
                let target = String(content[Range(match.range(at: 1), in: content)!])
                guard !target.contains("://") else { return nil }
                let resolved = ((dir as NSString).appendingPathComponent(target) as NSString).standardizingPath
                return fm.fileExists(atPath: vault.appendingPathComponent(resolved).path) ? nil : "\(path) → \(target)"
            }
        }
    }

    private func pending(_ base: URL) -> PendingApprovals {
        PendingApprovals(base: base) { [unowned self] title, body in notices.append((title, body)) }
    }

    private func state(_ dir: URL) throws -> MeetingPipelineState {
        try JSONDecoder().decode(MeetingPipelineState.self, from: Data(contentsOf: dir.appendingPathComponent(MeetingPipelineState.stateFileName)))
    }

    private func hasProposal(_ dir: URL) -> Bool {
        fm.fileExists(atPath: dir.appendingPathComponent(MeetingProposal.fileName).path)
    }

    /// The copies in `.ok/local/voicetype-preserved/<txid>/` holding
    /// `content`, spelled from the vault root the journal records.
    private func preservedCopies(_ vault: URL, holding content: String) throws -> [String] {
        let root = try OKVaultIdentity.of(vault).root + "/.ok/local/voicetype-preserved"
        var found: [String] = []
        for tx in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            for name in try fm.contentsOfDirectory(atPath: root + "/" + tx) {
                let path = root + "/" + tx + "/" + name
                if (try? Data(contentsOf: URL(fileURLWithPath: path))) == Data(content.utf8) { found.append(path) }
            }
        }
        return found.sorted()
    }

    /// A meeting directory under `base` with its proposal and `pipeline.json`
    /// (as the processor leaves them): a new decision and an update of the gotcha.
    private func seedMeeting(_ name: String, title: String = "Sprint review", base: URL, vault: URL?) throws -> (dir: URL, proposal: MeetingProposal) {
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let meetingID = UUID()
        let note = MeetingNote(startedAt: date, duration: 1800, summary: MeetingSummary(title: title, summary: "Revisamos."),
                               transcript: "Você: oi")
        let paths = OKMeetingPaths.make(project: "p5", startedAt: date, title: title, timeZone: utc)
        let p = MeetingProposal(
            meetingID: meetingID, note: note, vault: try vault.map(OKVaultIdentity.of), suggestedProject: "p5", project: "p5", paths: paths,
            items: [
                OKProposedItem(action: .new, type: .decisao, path: decisionPath, title: "Usar fila",
                               markdown: "---\ntitle: Usar fila\ndescription: d\ntype: decisao\nproject: p5\n---\n# Usar fila\n\n## Fontes\n\n- [\(title)](\(OKPath.relativeLink(from: decisionPath, to: paths.record)))\n"),
                OKProposedItem(action: .update, type: .gotcha, path: gotchaPath, title: "G", markdown: newGotcha,
                               baseHash: OKPath.contentHash(Data("old gotcha\n".utf8)), baseContent: "old gotcha\n"),
            ]
        )
        let outcome = try MeetingProposalStore.replaceFromReprocessing(p, in: dir, builtFrom: MeetingPipelineState(noteID: meetingID)) {
            $0.okProcessed = true
            $0.summarized = true
        }
        XCTAssertEqual(outcome, .replaced)
        return (dir, p)
    }

    private struct Commit {
        var dir: URL
        var proposal: MeetingProposal
        var ops: [OKVaultOp]
        func index(_ path: String) -> Int { ops.firstIndex { $0.path == path }! }
    }

    /// Everything approved, ops built by the session; `fault` sees the ops to
    /// pick indices. The commit must die (`OKSimulatedCrash`) or end with
    /// `WriteError.incomplete`, leaving the journal.
    private func interruptedCommit(
        base: URL, vault: URL, fault: @escaping @Sendable ([OKVaultOp], OKFaultPoint) throws -> Void
    ) throws -> Commit {
        let (dir, p) = try seedMeeting("2026-10-16_143000", base: base, vault: vault)
        var session = OKApprovalSession(proposal: p, progress: nil, timeZone: utc)
        for _ in 0..<4 { session.approve() }
        XCTAssertTrue(session.canCommit)
        try session.progress.save(in: dir)

        let identity = try OKVaultIdentity.of(vault)
        let ops = try session.commitOps(vault: vault, now: date)
        var writer = OKVaultWriter(vault: vault, identity: identity,
                                   journalDirectory: dir.appendingPathComponent(MeetingProposalStore.journalFolder))
        writer.fault = { try fault(ops, $0) }
        do {
            let result = try writer.commit(ops, dependencies: session.commitDependencies(),
                                           receipt: session.receiptDraft(vault: identity), precondition: { true })
            XCTFail("o commit deveria ter morrido, veio \(result)")
        } catch is OKSimulatedCrash {
        } catch OKVaultWriter.WriteError.incomplete {}
        XCTAssertTrue(MeetingProposalStore.hasJournal(dir))
        return Commit(dir: dir, proposal: p, ops: ops)
    }

    // MARK: - Tests

    func testDiscardRemovesProposalAndRefreshes() throws {
        defer { removeTemps() }
        let base = try makeTemp()
        let a = try seedMeeting("2026-10-15_090000", title: "Daily", base: base, vault: nil)
        let b = try seedMeeting("2026-10-16_090000", title: "Review", base: base, vault: nil)
        let pending = pending(base)
        XCTAssertTrue(pending.items.isEmpty)

        pending.refresh()
        XCTAssertEqual(pending.items.count, 2)

        let discarded = pending.items[0]
        pending.discard(discarded)
        XCTAssertEqual(pending.items.count, 1)
        XCTAssertNotEqual(pending.items[0].id, discarded.id)
        XCTAssertFalse(hasProposal(discarded.directory))
        XCTAssertTrue(hasProposal([a.dir, b.dir].first { $0.lastPathComponent != discarded.id }!))
        // The meeting itself stays on the Mac.
        XCTAssertTrue(fm.fileExists(atPath: discarded.directory.appendingPathComponent(MeetingPipelineState.stateFileName).path))
    }

    func testBootstrapRollsBackInterruptedCommit() throws {
        defer { removeTemps() }
        let base = try makeTemp()
        let vault = try makeVault()
        let original = snapshot(vault)
        let c = try interruptedCommit(base: base, vault: vault) { _, point in
            if point == .afterApply(0) { throw OKSimulatedCrash() }
        }
        XCTAssertNotEqual(snapshot(vault), original)

        let pending = pending(base)
        pending.bootstrap()

        XCTAssertEqual(snapshot(vault), original)
        XCTAssertFalse(MeetingProposalStore.hasJournal(c.dir))
        XCTAssertEqual(MeetingProposalStore.load(c.dir), c.proposal)
        XCTAssertEqual(OKApprovalProgress.load(c.dir)?.generation, c.proposal.generation)
        XCTAssertEqual(pending.items.map(\.id), [c.dir.lastPathComponent])
        XCTAssertNil(try state(c.dir).okRecordPath)
        XCTAssertTrue(notices.isEmpty, "\(notices)")
    }

    func testBootstrapFinalizesCommittedJournal() throws {
        defer { removeTemps() }
        let base = try makeTemp()
        let vault = try makeVault()
        let c = try interruptedCommit(base: base, vault: vault) { _, point in
            if point == .afterReceipt { throw OKSimulatedCrash() }
        }
        let paths = try XCTUnwrap(c.proposal.paths)

        let pending = pending(base)
        pending.bootstrap()

        let s = try state(c.dir)
        XCTAssertEqual(s.okRecordPath, paths.record)
        XCTAssertEqual(s.okTranscriptPath, paths.transcript)
        XCTAssertEqual(s.okVault, try OKVaultIdentity.of(vault))
        XCTAssertEqual(s.okProject, "p5")
        XCTAssertFalse(hasProposal(c.dir))
        XCTAssertNil(OKApprovalProgress.load(c.dir))
        XCTAssertFalse(MeetingProposalStore.hasJournal(c.dir))
        XCTAssertTrue(pending.items.isEmpty)
        XCTAssertNotNil(text(paths.record, in: vault))
        XCTAssertEqual(text(gotchaPath, in: vault), newGotcha)
        XCTAssertEqual(brokenLinks(vault), [])
        // The gotcha's old version is kept aside as is: no notice.
        XCTAssertEqual(try preservedCopies(vault, holding: "old gotcha\n").count, 1)
        XCTAssertTrue(notices.isEmpty, "\(notices)")
    }

    /// The same crash, but an editor that kept the gotcha open wrote its old
    /// version after the receipt: the launch finalizes, `finish` keeps that
    /// edit aside, and the notice says where it is.
    func testBootstrapAnnouncesOutsideEditKeptByFinish() throws {
        defer { removeTemps() }
        let base = try makeTemp()
        let vault = try makeVault()
        let editor = try FileHandle(forUpdating: vault.appendingPathComponent(gotchaPath))
        defer { try? editor.close() }
        let c = try interruptedCommit(base: base, vault: vault) { _, point in
            guard point == .afterReceipt else { return }
            try writeThrough(editor, "editado fora\n")
            throw OKSimulatedCrash()
        }

        let pending = pending(base)
        pending.bootstrap()

        XCTAssertFalse(MeetingProposalStore.hasJournal(c.dir))
        XCTAssertFalse(hasProposal(c.dir))
        XCTAssertTrue(pending.items.isEmpty)
        XCTAssertEqual(text(gotchaPath, in: vault), newGotcha)
        let copies = try preservedCopies(vault, holding: "editado fora\n")
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(notices.map(\.title), ["Edição externa guardada à parte"])
        XCTAssertEqual(notices.first?.body, "“Sprint review” foi gravada no vault, mas outro app editou \(gotchaPath) durante a gravação e o vault ficou com a versão do VoiceType. A edição foi guardada em \(copies.first ?? "").")
    }

    func testBootstrapCompletesInterruptedCompletionAndReviewsConflicts() throws {
        defer { removeTemps() }
        // 1. Record edited from outside after it was applied, crash before the
        //    next op and again inside the completion → the completion finishes.
        do {
            let base = try makeTemp()
            let vault = try makeVault()
            let records = Box<String?>(nil)
            let c = try interruptedCommit(base: base, vault: vault) { ops, point in
                let record = recordIndex(ops)
                switch point {
                case .afterApply(record):
                    let edited = (text(ops[record].path, in: vault) ?? "") + "\nEditado no OpenKnowledge.\n"
                    records.value = edited
                    try put(edited, ops[record].path, in: vault)
                case .beforeApply(record + 1): throw OKSimulatedCrash()
                default: break
                }
            }
            let paths = try XCTUnwrap(c.proposal.paths)
            let decision = c.index(decisionPath)
            XCTAssertThrowsError(try OKVaultWriter.recover(
                journalDirectory: c.dir.appendingPathComponent(MeetingProposalStore.journalFolder),
                fault: { if $0 == .forwardBeforeApply(decision) { throw OKSimulatedCrash() } }
            ))
            XCTAssertTrue(MeetingProposalStore.hasJournal(c.dir))

            let pending = pending(base)
            pending.bootstrap()

            XCTAssertEqual(text(paths.record, in: vault), records.value)
            XCTAssertNotNil(text(paths.transcript, in: vault))
            XCTAssertNotNil(text(decisionPath, in: vault))
            XCTAssertEqual(text(gotchaPath, in: vault), newGotcha)
            XCTAssertEqual(brokenLinks(vault), [])
            XCTAssertEqual(try state(c.dir).okRecordPath, paths.record)
            XCTAssertFalse(hasProposal(c.dir))
            XCTAssertFalse(MeetingProposalStore.hasJournal(c.dir))
            XCTAssertTrue(pending.items.isEmpty)
            XCTAssertTrue(notices.isEmpty, "\(notices)")
        }

        // 2. Same, with the gotcha changed from outside before its turn → only
        //    that item goes back to review, and the user is told.
        notices = []
        do {
            let base = try makeTemp()
            let vault = try makeVault()
            let c = try interruptedCommit(base: base, vault: vault) { ops, point in
                let record = recordIndex(ops)
                let gotcha = ops.firstIndex { $0.path == gotchaPath }!
                switch point {
                case .afterApply(record):
                    try put((text(ops[record].path, in: vault) ?? "") + "\nEditado.\n", ops[record].path, in: vault)
                case .beforeApply(gotcha):
                    try put("atual\n", gotchaPath, in: vault)
                    throw OKSimulatedCrash()
                default: break
                }
            }
            let paths = try XCTUnwrap(c.proposal.paths)
            let gotchaItem = c.proposal.items[1]

            let pending = pending(base)
            pending.bootstrap()

            XCTAssertEqual(text(gotchaPath, in: vault), "atual\n")
            XCTAssertNotNil(text(paths.transcript, in: vault))
            XCTAssertNotNil(text(decisionPath, in: vault))
            XCTAssertEqual(brokenLinks(vault), [])
            XCTAssertFalse(MeetingProposalStore.hasJournal(c.dir))
            let p = try XCTUnwrap(MeetingProposalStore.load(c.dir))
            XCTAssertEqual(p.generation, c.proposal.generation)
            XCTAssertTrue(p.recordWritten)
            XCTAssertEqual(p.fixedPaths, paths)
            XCTAssertEqual(p.items.map(\.id), [gotchaItem.id])
            XCTAssertEqual(p.items.first?.baseContent, "atual\n")
            XCTAssertEqual(try state(c.dir).okRecordPath, paths.record)
            XCTAssertEqual(pending.items.map(\.id), [c.dir.lastPathComponent])
            XCTAssertEqual(notices.map(\.title), ["Gravação no vault concluída em parte"])
            XCTAssertEqual(notices.first?.body,
                           "1 item de “Sprint review” mudou durante a gravação e voltou para revisão. O registro e a transcrição já estão no vault.")
        }

        // 3. Record deleted during the completion and its restore failing →
        //    "incompleta": the proposal and the journal stay, and so does the
        //    pending meeting. Without the failure, the next launch completes.
        notices = []
        do {
            let base = try makeTemp()
            let vault = try makeVault()
            let c = try interruptedCommit(base: base, vault: vault) { ops, point in
                let decision = ops.firstIndex { $0.path == decisionPath }!
                switch point {
                case .afterApply(decision):
                    try put((text(decisionPath, in: vault) ?? "") + "\nEditado.\n", decisionPath, in: vault)
                case .beforeApply(decision + 1):
                    let record = recordIndex(ops)
                    try FileManager.default.removeItem(at: vault.appendingPathComponent(ops[record].path))
                    throw OKSimulatedCrash()
                default: break
                }
            }
            let paths = try XCTUnwrap(c.proposal.paths)
            let record = c.index(paths.record)

            let pending = pending(base)
            pending.recoverFault = { if $0 == .forwardBeforeRestore(record) { throw Boom() } }
            pending.bootstrap()

            XCTAssertNil(text(paths.record, in: vault))
            XCTAssertTrue(hasProposal(c.dir))
            XCTAssertTrue(MeetingProposalStore.hasJournal(c.dir))
            XCTAssertNil(try state(c.dir).okRecordPath)
            XCTAssertEqual(pending.items.map(\.id), [c.dir.lastPathComponent])
            XCTAssertEqual(notices.map(\.title), ["Gravação no vault incompleta"])
            XCTAssertEqual(notices.first?.body,
                           "Faltou gravar \(paths.record). O VoiceType tenta de novo no próximo início ou ao abrir a reunião.")

            notices = []
            let next = self.pending(base)
            next.bootstrap()
            XCTAssertNotNil(text(paths.record, in: vault))
            XCTAssertEqual(brokenLinks(vault), [])
            XCTAssertFalse(MeetingProposalStore.hasJournal(c.dir))
            XCTAssertFalse(hasProposal(c.dir))
            XCTAssertTrue(next.items.isEmpty)
            XCTAssertTrue(notices.isEmpty, "\(notices)")
        }
    }

    /// `PendingApprovals` has no config at all: whatever vault the settings
    /// point at (B), recovery acts only on the vault in the journal (A).
    /// Launch order: recovery (`AppDelegate`) runs before the authorization
    /// request answers, and the production `Notifier` drops every
    /// notification until then. The notice waits and arrives after the grant.
    func testRecoveryNoticesWaitForNotificationAuthorization() async throws {
        defer { removeTemps() }
        let base = try makeTemp()
        let vault = try makeVault()
        let c = try interruptedCommit(base: base, vault: vault) { _, point in
            if point == .afterApply(0) { throw OKSimulatedCrash() }
        }
        let root = try OKVaultIdentity.of(vault).root
        try fm.removeItem(at: vault)

        let center = SlowAuthCenter()
        let notifier = Notifier(center: center, now: Date.init)
        let pending = PendingApprovals(base: base, notifier: notifier)
        pending.bootstrap()
        let authorization = Task { await notifier.bootstrap() }
        try await waitUntil { center.isAsking }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(center.bodies, [])

        center.grant()
        await authorization.value
        try await waitUntil { !center.bodies.isEmpty }
        XCTAssertEqual(center.bodies, ["❌ \(ApprovalStrings.interruptedTitle) — \(ApprovalStrings.vaultUnavailableBody(root))"])
        XCTAssertTrue(MeetingProposalStore.hasJournal(c.dir))
        XCTAssertEqual(pending.items.map(\.id), [c.dir.lastPathComponent])
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("tempo esgotado esperando a condição", file: file, line: line)
    }

    func testBootstrapIgnoresConfiguredVaultAndUsesJournalVault() throws {
        defer { removeTemps() }
        let base = try makeTemp()
        let vaultA = try makeVault()
        let vaultB = try makeVault()
        let originalA = snapshot(vaultA)
        let originalB = snapshot(vaultB)
        let c = try interruptedCommit(base: base, vault: vaultA) { ops, point in
            if point == .afterApply(ops.count - 2) { throw OKSimulatedCrash() }
        }
        XCTAssertNotEqual(snapshot(vaultA), originalA)

        let pending = pending(base)
        pending.bootstrap()

        XCTAssertEqual(snapshot(vaultA), originalA)
        XCTAssertEqual(snapshot(vaultB), originalB)
        XCTAssertFalse(fm.fileExists(atPath: vaultB.appendingPathComponent(".ok/local").path))
        XCTAssertFalse(MeetingProposalStore.hasJournal(c.dir))
        XCTAssertEqual(pending.items.map(\.id), [c.dir.lastPathComponent])
    }
}

/// Answers the authorization request only when the test calls `grant()`,
/// like the first prompt at launch.
private final class SlowAuthCenter: UserNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var pendingAuth: CheckedContinuation<Bool, Never>?
    private var added: [UNNotificationRequest] = []

    var isAsking: Bool { lock.withLock { pendingAuth != nil } }
    var bodies: [String] { lock.withLock { added.map(\.content.body) } }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        await withCheckedContinuation { c in lock.withLock { pendingAuth = c } }
    }

    func add(_ request: UNNotificationRequest) async throws {
        lock.withLock { added.append(request) }
    }

    func grant() {
        let c = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
            defer { pendingAuth = nil }
            return pendingAuth
        }
        c?.resume(returning: true)
    }
}

private final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
