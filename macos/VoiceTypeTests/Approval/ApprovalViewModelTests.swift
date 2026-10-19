import Core
import XCTest
@testable import VoiceType

private let gotchaPath = "p5/gotchas/g.md"
private let decisionPath = "p5/decisoes/usar-fila.md"
private let oldGotcha = "old gotcha\n"
private let newGotcha = "---\ntitle: G\ndescription: d\ntype: gotcha\nproject: p5\n---\n# G novo\n"
private let gotchaB = "---\ntitle: G\ndescription: d\ntype: gotcha\nproject: p5\n---\nB\n"

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

private func textHash(_ s: String) -> String { OKPath.contentHash(Data(s.utf8)) }

private struct NotLoggedIn: LocalizedError {
    var errorDescription: String? { "not logged in" }
}

/// Answers from canned values and counts the calls. A new item cites the
/// meeting record; an update is written against the doc's current content,
/// as `ClaudeCLISummarizer` does.
private final class FakeAssistant: OKAssistant, @unchecked Sendable {
    private let lock = NSLock()
    private var _suggestCalls = 0
    private var _planCalls = 0
    private var _error: (any Error)?

    let suggestion: String?
    let plan: [OKPlannedItem]
    /// Markdown of every update item.
    let updateMarkdown: String
    /// Runs inside `suggestProject` before it answers.
    var onSuggest: (@Sendable () async -> Void)?

    init(suggestion: String? = "p5", plan: [OKPlannedItem] = [], updateMarkdown: String = "# B\n", error: (any Error)? = nil) {
        self.suggestion = suggestion
        self.plan = plan
        self.updateMarkdown = updateMarkdown
        _error = error
    }

    var suggestCalls: Int { lock.withLock { _suggestCalls } }
    var planCalls: Int { lock.withLock { _planCalls } }
    var error: (any Error)? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }

    func suggestProject(summary: MeetingSummary, projects: [OKProject]) async throws -> String? {
        lock.withLock { _suggestCalls += 1 }
        await onSuggest?()
        if let error { throw error }
        return suggestion
    }

    func planDistillation(summary: MeetingSummary, transcript: String, project: String, docs: [OKDocEntry]) async throws -> [OKPlannedItem] {
        lock.withLock { _planCalls += 1 }
        if let error { throw error }
        return plan
    }

    func writeDistillation(
        _ plan: [OKPlannedItem], summary: MeetingSummary, transcript: String, project: String, recordPath: String,
        meetingTitle: String, meetingDate: Date, templates: [OKKnowledgeType: String], current: [String: String]
    ) async throws -> [OKProposedItem] {
        if let error { throw error }
        return plan.map { item in
            switch item.action {
            case .new:
                let source = OKPath.relativeLink(from: item.path, to: recordPath)
                return OKProposedItem(action: .new, type: item.type, path: item.path, title: item.title, markdown:
                    "---\ntitle: \(item.title)\ndescription: d\ntype: \(item.type.rawValue)\nproject: \(project)\n---\n# \(item.title)\n\n## Fontes\n\n- [\(meetingTitle)](\(source))\n")
            case .update:
                let base = current[item.path]
                return OKProposedItem(action: .update, type: item.type, path: item.path, title: item.title, markdown: updateMarkdown,
                                      baseHash: base.map(textHash), baseContent: base)
            }
        }
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
}

/// Holds `suggestProject` until the test releases it.
private actor Gate {
    private var entered = false
    private var released = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
final class ApprovalViewModelTests: XCTestCase {
    private struct Boom: Error {}

    // 2026-10-16 14:30:00 UTC
    private let date = Date(timeIntervalSince1970: 1_792_161_000)
    private let fm = FileManager.default
    private var cleanup: [URL] = []
    private var notices: [(title: String, body: String)] = []
    private var base: URL!
    private var configStore: ConfigStore!
    private var center: NotifierTests.StubCenter!
    private var notifier: Notifier!
    private var clock: Clock!

    override func setUp() async throws {
        base = try makeTemp()
        configStore = ConfigStore.inMemory()
        center = NotifierTests.StubCenter()
        notifier = Notifier(center: center, now: { Date(timeIntervalSince1970: 0) })
        await notifier.bootstrap()
        clock = Clock(date)
    }

    override func tearDown() async throws {
        for url in cleanup { try? fm.removeItem(at: url) }
        cleanup = []
    }

    // MARK: - Fixtures

    private func makeTemp() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        cleanup.append(url)
        return url
    }

    private func makeVault() throws -> URL {
        let vault = try makeTemp()
        try fm.createDirectory(at: vault.appendingPathComponent(".ok"), withIntermediateDirectories: true)
        try put("---\ntitle: p5\ndescription: Projeto p5.\ntype: indice\nproject: p5\n---\n# p5\n\n## Conhecimento registrado\n", "p5/index.md", in: vault)
        try put("# Vault\n\n## Projetos\n\n- [p5 — Projeto p5.](./p5/index.md)\n", "README.md", in: vault)
        try put(oldGotcha, gotchaPath, in: vault)
        return vault
    }

    private func useVault(_ vault: URL) async throws {
        var cfg = AppConfig()
        cfg.meetingVaultKind = .openKnowledge
        cfg.openKnowledgeVaultPath = vault.path
        try await configStore.save(cfg)
    }

    private func pending() -> PendingApprovals {
        PendingApprovals(base: base) { [unowned self] title, body in notices.append((title, body)) }
    }

    private func makeVM(
        _ dir: URL, assistant: FakeAssistant? = nil, pending: PendingApprovals? = nil,
        fault: (@Sendable (OKFaultPoint) throws -> Void)? = nil
    ) -> ApprovalViewModel {
        let clock = clock!
        return ApprovalViewModel(
            directory: dir, configStore: configStore, notifier: notifier, pending: pending ?? self.pending(),
            assistantFactory: { _ in assistant }, now: { clock.now }, writerFault: fault
        )
    }

    private func note(_ title: String, at startedAt: Date? = nil) -> MeetingNote {
        MeetingNote(startedAt: startedAt ?? date, duration: 1800, summary: MeetingSummary(title: title, summary: "Revisamos."),
                    transcript: "Você: oi")
    }

    private func save(_ p: MeetingProposal, as name: String) throws -> URL {
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let outcome = try MeetingProposalStore.replaceFromReprocessing(p, in: dir, builtFrom: MeetingPipelineState(noteID: p.meetingID)) {
            $0.okProcessed = true
            $0.summarized = p.summaryFailure == nil
        }
        XCTAssertEqual(outcome, .replaced)
        return dir
    }

    /// Without the model: a new decision and an update of the gotcha, in `p5`.
    private func seedManual(_ name: String = "2026-10-16_143000", vault: URL) throws -> (dir: URL, proposal: MeetingProposal) {
        let n = note("Sprint review")
        let paths = OKMeetingPaths.make(project: "p5", startedAt: date, title: n.summary.title)
        let p = MeetingProposal(
            meetingID: UUID(), note: n, vault: try OKVaultIdentity.of(vault), suggestedProject: "p5", project: "p5", paths: paths,
            items: [
                OKProposedItem(action: .new, type: .decisao, path: decisionPath, title: "Usar fila",
                               markdown: "---\ntitle: Usar fila\ndescription: d\ntype: decisao\nproject: p5\n---\n# Usar fila\n\n## Fontes\n\n- [Sprint review](\(OKPath.relativeLink(from: decisionPath, to: paths.record)))\n"),
                OKProposedItem(action: .update, type: .gotcha, path: gotchaPath, title: "G", markdown: newGotcha,
                               baseHash: textHash(oldGotcha), baseContent: oldGotcha),
            ]
        )
        return (try save(p, as: name), p)
    }

    /// Through `OKProposalBuilder` with `assistant`, as the processor does.
    private func seedBuilt(
        _ name: String = "2026-10-16_143000", title: String = "Sprint review", at startedAt: Date? = nil,
        assistant: FakeAssistant?, vault: URL, summaryFailure: String? = nil
    ) async throws -> (dir: URL, proposal: MeetingProposal) {
        let state = MeetingPipelineState(noteID: UUID())
        let p = await OKProposalBuilder(assistant: assistant, user: "Tester")
            .build(note: note(title, at: startedAt), summaryFailure: summaryFailure, state: state, vault: vault, now: clock.now)
        return (try save(p, as: name), p)
    }

    private func decisionPlan() -> [OKPlannedItem] {
        [OKPlannedItem(action: .new, type: .decisao, path: decisionPath, title: "Usar fila", reason: "decidido")]
    }

    private func state(_ dir: URL) throws -> MeetingPipelineState {
        try JSONDecoder().decode(MeetingPipelineState.self, from: Data(contentsOf: dir.appendingPathComponent(MeetingPipelineState.stateFileName)))
    }

    private func exists(_ name: String, in dir: URL) -> Bool {
        fm.fileExists(atPath: dir.appendingPathComponent(name).path)
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
    private func brokenRelativeLinks(_ vault: URL) -> [String] {
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

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "a condição não se cumpriu", file: file, line: line)
    }

    // MARK: - Progress

    func testClosingMidwayPersistsProgressAndWritesNothing() async throws {
        let vault = try makeVault()
        try await useVault(vault)
        let (dir, _) = try seedManual(vault: vault)
        let before = snapshot(vault)

        var vm = makeVM(dir)
        await vm.load()
        XCTAssertEqual(vm.session?.current, .project)
        vm.approve()
        XCTAssertEqual(vm.session?.current, .record)
        vm.edit("x")

        vm = makeVM(dir)
        await vm.load()
        XCTAssertEqual(vm.session?.current, .record)
        XCTAssertEqual(vm.session?.markdown(for: .record), "x")
        XCTAssertEqual(snapshot(vault), before)
    }

    // MARK: - Commit

    func testCommitConflictKeepsPendingAndShowsBanner() async throws {
        let vault = try makeVault()
        try await useVault(vault)
        let (dir, p) = try seedManual(vault: vault)
        try put("gotcha editado\n", gotchaPath, in: vault)
        let before = snapshot(vault)

        let vm = makeVM(dir)
        await vm.load()
        for _ in 0..<4 { vm.approve() }
        XCTAssertEqual(vm.session?.canCommit, true)

        let ok = await vm.commit()
        XCTAssertFalse(ok)
        XCTAssertNotNil(vm.banner)
        XCTAssertTrue(exists(MeetingProposal.fileName, in: dir))
        XCTAssertFalse(MeetingProposalStore.hasJournal(dir))
        XCTAssertEqual(snapshot(vault), before)
        let gotcha = p.items[1].id
        XCTAssertEqual(vm.session?.current, .item(gotcha))
        XCTAssertEqual(vm.session?.previousMarkdown(for: .item(gotcha)), "gotcha editado\n")
        XCTAssertEqual(MeetingProposalStore.load(dir)?.items[1].baseHash, textHash("gotcha editado\n"))
    }

    func testCommitSuccessClearsPendingAndRecordsFixedPaths() async throws {
        let vault = try makeVault()
        try await useVault(vault)
        let (dir, p) = try seedManual(vault: vault)
        let vm = makeVM(dir)
        await vm.load()
        for _ in 0..<4 { vm.approve() }

        let ok = await vm.commit()
        XCTAssertTrue(ok, vm.banner ?? "")
        XCTAssertFalse(exists(MeetingProposal.fileName, in: dir))
        XCTAssertFalse(exists(OKApprovalProgress.fileName, in: dir))
        XCTAssertFalse(exists(MeetingProposalStore.journalFolder, in: dir))
        let s = try state(dir)
        XCTAssertEqual(s.okRecordPath, p.paths?.record)
        XCTAssertEqual(s.okVault, try OKVaultIdentity.of(vault))
        XCTAssertNotNil(text(p.paths!.record, in: vault))
        XCTAssertNotNil(text(p.paths!.transcript, in: vault))
        XCTAssertNotNil(text(decisionPath, in: vault))
        XCTAssertEqual(text(gotchaPath, in: vault), newGotcha)
        XCTAssertEqual(brokenRelativeLinks(vault), [])
        // The gotcha's old version is kept aside as is: only the success.
        XCTAssertEqual(try preservedCopies(vault, holding: oldGotcha).count, 1)
        XCTAssertEqual(center.addedRequests.map(\.content.body), ["✓ Reunião gravada no vault — \(p.paths!.record)"])
    }

    /// An editor kept the gotcha open and, after the receipt, writes the old
    /// version `finish` then keeps aside: the commit still succeeds, and the
    /// user is told where that edit is.
    func testOutsideEditKeptByFinishIsAnnouncedWithItsCopy() async throws {
        let vault = try makeVault()
        try await useVault(vault)
        let (dir, p) = try seedManual(vault: vault)
        let editor = try FileHandle(forUpdating: vault.appendingPathComponent(gotchaPath))
        defer { try? editor.close() }
        let vm = makeVM(dir, fault: { point in
            if point == .afterReceipt { try writeThrough(editor, "editado fora\n") }
        })
        await vm.load()
        for _ in 0..<4 { vm.approve() }

        let ok = await vm.commit()
        XCTAssertTrue(ok, vm.banner ?? "")
        XCTAssertFalse(MeetingProposalStore.hasJournal(dir))
        XCTAssertFalse(exists(MeetingProposal.fileName, in: dir))
        XCTAssertEqual(text(gotchaPath, in: vault), newGotcha)
        let copies = try preservedCopies(vault, holding: "editado fora\n")
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(center.addedRequests.map(\.content.body), [
            "✓ Reunião gravada no vault — \(p.paths!.record)",
            "❌ Edição externa guardada à parte — " + "“Sprint review” foi gravada no vault, mas outro app editou \(gotchaPath) durante a gravação e o vault ficou com a versão do VoiceType. A edição foi guardada em \(copies.first ?? "").",
        ])
    }

    func testCatalogChangedAfterLoadRedistillsAndWritesNothing() async throws {
        let vault = try makeVault()
        try await useVault(vault)
        let fake = FakeAssistant(plan: decisionPlan())
        let (dir, _) = try await seedBuilt(assistant: fake, vault: vault)
        XCTAssertEqual(fake.planCalls, 1)

        let vm = makeVM(dir, assistant: fake)
        await vm.load()
        for _ in 0..<3 { vm.approve() }
        XCTAssertEqual(vm.session?.canCommit, true)
        try put("---\ntitle: Fila\n---\n# Fila\n", "p5/decisoes/outro-slug-mesmo-tema.md", in: vault)
        let before = snapshot(vault)

        let ok = await vm.commit()
        XCTAssertFalse(ok)
        XCTAssertEqual(fake.planCalls, 2)
        XCTAssertEqual(snapshot(vault), before)
        XCTAssertEqual(vm.banner, ApprovalStrings.redistilled)
        XCTAssertFalse(MeetingProposalStore.hasJournal(dir))
    }

    func testBaseChangedAfterLoadSameMarkdownStillRequiresReapproval() async throws {
        let vault = try makeVault()
        try await useVault(vault)
        let fake = FakeAssistant(plan: [OKPlannedItem(action: .update, type: .gotcha, path: gotchaPath, title: "G", reason: "r")],
                                 updateMarkdown: gotchaB)
        let (dir, _) = try await seedBuilt(assistant: fake, vault: vault)
        let vm = makeVM(dir, assistant: fake)
        await vm.load()
        for _ in 0..<3 { vm.approve() }
        XCTAssertEqual(vm.session?.canCommit, true)

        // Another agent writes C; the redistillation answers the same B.
        try put("C\n", gotchaPath, in: vault)
        var ok = await vm.commit()
        XCTAssertFalse(ok)
        let item = try XCTUnwrap(vm.session?.proposal.items.first?.id)
        XCTAssertEqual(vm.session?.isApproved(item), false)
        XCTAssertEqual(vm.session?.current, .item(item))
        XCTAssertEqual(vm.session?.markdown(for: .item(item)), gotchaB)
        XCTAssertEqual(vm.session?.previousMarkdown(for: .item(item)), "C\n")
        XCTAssertEqual(text(gotchaPath, in: vault), "C\n")

        vm.approve()
        ok = await vm.commit()
        XCTAssertTrue(ok, vm.banner ?? "")
        XCTAssertEqual(text(gotchaPath, in: vault), gotchaB)
    }

    func testProposalAgingPast24hWithWindowOpenRedistills() async throws {
        let vault = try makeVault()
        try await useVault(vault)
        let fake = FakeAssistant(plan: decisionPlan())
        let (dir, _) = try await seedBuilt(assistant: fake, vault: vault)
        let vm = makeVM(dir, assistant: fake)
        await vm.load()
        for _ in 0..<3 { vm.approve() }
        let before = snapshot(vault)

        clock.now = date.addingTimeInterval(25 * 3600)
        let ok = await vm.commit()
        XCTAssertFalse(ok)
        XCTAssertEqual(fake.planCalls, 2)
        XCTAssertEqual(snapshot(vault), before)
    }

    func testDocChangedBeforeReopenRedistillsOnLoadAndExplains() async throws {
        let vault = try makeVault()
        try await useVault(vault)
        let fake = FakeAssistant(plan: [OKPlannedItem(action: .update, type: .gotcha, path: gotchaPath, title: "G", reason: "r")],
                                 updateMarkdown: gotchaB)
        let (dir, _) = try await seedBuilt(assistant: fake, vault: vault)
        var vm = makeVM(dir, assistant: fake)
        await vm.load()
        for _ in 0..<3 { vm.approve() }
        XCTAssertEqual(vm.session?.canCommit, true)

        // The window is closed while someone edits the doc; reopening redistills.
        try put("C\n", gotchaPath, in: vault)
        let before = snapshot(vault)
        vm = makeVM(dir, assistant: fake)
        await vm.load()
        XCTAssertEqual(fake.planCalls, 2)
        XCTAssertEqual(vm.banner, ApprovalStrings.redistilled)
        let item = try XCTUnwrap(vm.session?.proposal.items.first?.id)
        XCTAssertEqual(vm.session?.current, .item(item))
        XCTAssertEqual(vm.session?.previousMarkdown(for: .item(item)), "C\n")
        XCTAssertEqual(snapshot(vault), before)
    }

    func testSameDaySameTitleSecondMeetingCitesItsOwnRecord() async throws {
        let vault = try makeVault()
        try await useVault(vault)
        let fake = FakeAssistant(plan: decisionPlan())
        let first = try await seedBuilt("2026-10-16_143000", title: "Daily", assistant: fake, vault: vault)
        let second = try await seedBuilt("2026-10-16_153000", title: "Daily", at: date.addingTimeInterval(3600), assistant: fake, vault: vault)
        XCTAssertEqual(first.proposal.paths, second.proposal.paths)

        // The first one, record only.
        let vm1 = makeVM(first.dir, assistant: fake)
        await vm1.load()
        vm1.approve()
        vm1.approve()
        vm1.skip()
        var ok = await vm1.commit()
        XCTAssertTrue(ok, vm1.banner ?? "")
        let taken = try XCTUnwrap(first.proposal.paths?.record)
        XCTAssertNotNil(text(taken, in: vault))

        // The second one, with its ADR: the record's name moves first.
        let vm2 = makeVM(second.dir, assistant: fake)
        await vm2.load()
        for _ in 0..<3 { vm2.approve() }
        XCTAssertEqual(vm2.session?.canCommit, true)
        ok = await vm2.commit()
        XCTAssertFalse(ok)
        let record = try XCTUnwrap(vm2.session?.paths?.record)
        XCTAssertTrue(record.hasSuffix("-daily-2.md"), record)
        XCTAssertEqual(vm2.banner, ApprovalStrings.relocated(from: taken, to: record))
        XCTAssertFalse(fm.fileExists(atPath: vault.appendingPathComponent(decisionPath).path))

        XCTAssertEqual(vm2.session?.current, .record)
        while vm2.session?.isFinished == false { vm2.approve() }
        ok = await vm2.commit()
        XCTAssertTrue(ok, vm2.banner ?? "")
        let adr = try XCTUnwrap(text(decisionPath, in: vault))
        XCTAssertTrue(adr.contains("](../reunioes/\((record as NSString).lastPathComponent))"), adr)
        XCTAssertTrue(record.hasSuffix("2026-10-16-daily-2.md"), record)
        XCTAssertTrue(try XCTUnwrap(text(record, in: vault)).contains("id: \(second.proposal.note.id.uuidString)"))
        XCTAssertEqual(brokenRelativeLinks(vault), [])
    }

    // MARK: - Without the model

    func testRecordOnlyApprovalWithoutAssistant() async throws {
        let vault = try makeVault()
        try await useVault(vault)
        let (dir, p) = try await seedBuilt(assistant: nil, vault: vault, summaryFailure: "Groq fora do ar")
        XCTAssertNil(p.suggestedProject)
        XCTAssertNil(p.paths)

        var vm = makeVM(dir)
        await vm.load()
        XCTAssertEqual(vm.session?.current, .project)
        await vm.choose("p5")
        XCTAssertEqual(vm.session?.paths?.record.hasPrefix("p5/reunioes/"), true)
        XCTAssertEqual(vm.session?.needsRedistill, false)
        XCTAssertNil(vm.banner)
        // `replaceProposal` already moved past the project step.
        XCTAssertEqual(vm.session?.current, .record)
        vm.approve()
        XCTAssertEqual(vm.session?.isFinished, true)

        vm = makeVM(dir)
        await vm.load()
        XCTAssertEqual(vm.session?.current, .record)
        XCTAssertEqual(vm.session?.recordApproved, true)
        clock.now = date.addingTimeInterval(25 * 3600)

        let ok = await vm.commit()
        XCTAssertTrue(ok, vm.banner ?? "")
        let record = try XCTUnwrap(try state(dir).okRecordPath)
        XCTAssertNotNil(text(record, in: vault))
        XCTAssertNotNil(text(try XCTUnwrap(try state(dir).okTranscriptPath), in: vault))
        XCTAssertTrue(fm.fileExists(atPath: vault.appendingPathComponent("p5/reunioes/.ok/frontmatter.yml").path))
        XCTAssertFalse(fm.fileExists(atPath: vault.appendingPathComponent("p5/decisoes").path))
        XCTAssertFalse(exists(MeetingProposal.fileName, in: dir))
    }

    func testRecordOnlyWithNewProjectAndThrowingAssistant() async throws {
        let vault = try makeVault()
        try await useVault(vault)
        let fake = FakeAssistant(error: NotLoggedIn())
        let (dir, p) = try await seedBuilt(assistant: fake, vault: vault)
        XCTAssertNotNil(p.distillationError)
        XCTAssertNil(p.project)

        let vm = makeVM(dir, assistant: fake)
        await vm.load()
        try await vm.createProject(slug: "acme", description: "Acme")
        XCTAssertEqual(fake.planCalls, 1)
        XCTAssertEqual(vm.session?.needsRedistill, false)
        XCTAssertEqual(vm.session?.proposal.project, "acme")
        XCTAssertEqual(vm.banner, ApprovalStrings.distillFailed("acme", "not logged in"))
        XCTAssertEqual(vm.session?.current, .record)
        vm.approve()

        let ok = await vm.commit()
        XCTAssertTrue(ok, vm.banner ?? "")
        XCTAssertEqual(fake.planCalls, 1)
        XCTAssertNotNil(text("acme/index.md", in: vault))
        XCTAssertTrue(fm.fileExists(atPath: vault.appendingPathComponent("acme/decisoes/.ok/frontmatter.yml").path))
        XCTAssertTrue(try XCTUnwrap(text("README.md", in: vault)).contains("./acme/index.md"))
        let s = try state(dir)
        XCTAssertEqual(s.okProject, "acme")
        XCTAssertNotNil(text(try XCTUnwrap(s.okRecordPath), in: vault))
        XCTAssertNotNil(text(try XCTUnwrap(s.okTranscriptPath), in: vault))
        XCTAssertEqual(brokenRelativeLinks(vault), [])
    }

    func testNewProjectConfirmedAgainAfterBackIsStillCreated() async throws {
        let vault = try makeVault()
        try await useVault(vault)
        let fake = FakeAssistant()
        let (dir, _) = try await seedBuilt(assistant: fake, vault: vault)
        let vm = makeVM(dir, assistant: fake)
        await vm.load()
        try await vm.createProject(slug: "acme", description: "Acme")
        XCTAssertEqual(vm.session?.current, .record)

        // Back to the project step and "Aprovar" again, as the window does.
        vm.back()
        XCTAssertEqual(vm.session?.current, .project)
        await vm.choose("acme")
        XCTAssertEqual(vm.session?.progress.newProject, OKNewProject(slug: "acme", description: "Acme"))
        XCTAssertEqual(OKApprovalProgress.load(dir)?.newProject, OKNewProject(slug: "acme", description: "Acme"))
        XCTAssertEqual(vm.session?.current, .project)
        vm.approve()
        vm.approve()
        XCTAssertEqual(vm.session?.isFinished, true)

        let ok = await vm.commit()
        XCTAssertTrue(ok, vm.banner ?? "")
        let index = try XCTUnwrap(text("acme/index.md", in: vault))
        XCTAssertTrue(index.contains("type: indice"), index)
        XCTAssertTrue(try XCTUnwrap(text("README.md", in: vault)).contains("./acme/index.md"))
        for file in OKProjectScaffold.folderMetadata(project: "acme") {
            XCTAssertEqual(text(file.path, in: vault), file.content, file.path)
        }
        XCTAssertEqual(try OKVaultCatalog.projects(in: vault).map(\.slug), ["acme", "p5"])
        XCTAssertEqual(brokenRelativeLinks(vault), [])
    }

    func testDistillationUnavailableAtCommitAllowsRecordOnly() async throws {
        let vault = try makeVault()
        try await useVault(vault)
        let fake = FakeAssistant(plan: decisionPlan())
        let (dir, p) = try await seedBuilt(assistant: fake, vault: vault)
        let vm = makeVM(dir, assistant: fake)
        await vm.load()
        for _ in 0..<3 { vm.approve() }
        let before = snapshot(vault)

        clock.now = date.addingTimeInterval(25 * 3600)
        fake.error = NotLoggedIn()
        var ok = await vm.commit()
        XCTAssertFalse(ok)
        XCTAssertEqual(vm.banner, ApprovalStrings.redistillFailed("not logged in"))
        XCTAssertEqual(snapshot(vault), before)

        vm.back()
        XCTAssertEqual(vm.session?.current, .item(p.items[0].id))
        vm.skip()
        ok = await vm.commit()
        XCTAssertTrue(ok, vm.banner ?? "")
        XCTAssertNotNil(text(try XCTUnwrap(p.paths?.record), in: vault))
        XCTAssertNotNil(text(try XCTUnwrap(p.paths?.transcript), in: vault))
        XCTAssertNil(text(decisionPath, in: vault))
        XCTAssertEqual(brokenRelativeLinks(vault), [])
    }

    // MARK: - Generations

    func testReprocessWhileWindowOpenInvalidatesOldSession() async throws {
        let vault = try makeVault()
        try await useVault(vault)
        let (dir, p1) = try seedManual(vault: vault)
        let pending = pending()
        pending.refresh()
        let vm = makeVM(dir, pending: pending)
        await vm.load()
        // Bound to P1 and never told about the reprocess.
        let stale = makeVM(dir)
        await stale.load()
        stale.approve()
        XCTAssertEqual(stale.session?.current, .record)

        vm.approve()
        vm.edit("x")
        vm.approve()
        let before = snapshot(vault)

        var p2 = p1
        p2.generation = UUID()
        p2.note.summary.summary = "Outro resumo."
        XCTAssertEqual(try MeetingProposalStore.replaceFromReprocessing(p2, in: dir, builtFrom: try state(dir)) { $0.okProcessed = true }, .replaced)
        pending.refresh()

        try await waitUntil { vm.session?.generation == p2.generation }
        XCTAssertEqual(vm.session?.current, .project)
        XCTAssertNil(vm.session?.progress.recordEdit)
        XCTAssertEqual(vm.banner, ApprovalStrings.reprocessed)

        stale.edit("y")
        XCTAssertEqual(MeetingProposalStore.load(dir), p2)
        XCTAssertFalse(exists(OKApprovalProgress.fileName, in: dir))
        XCTAssertEqual(stale.session?.generation, p2.generation)
        let ok = await stale.commit()
        XCTAssertFalse(ok)
        XCTAssertEqual(snapshot(vault), before)
        XCTAssertEqual(MeetingProposalStore.load(dir), p2)
    }

    func testRecordWrittenSessionNeverFinalizesWithMissingDependency() async throws {
        let vault = try makeVault()
        try await useVault(vault)
        let oldADR = "---\ntitle: Usar fila\ndescription: d\ntype: decisao\nproject: p5\n---\n# Usar fila\n"
        try put(oldADR, decisionPath, in: vault)
        let n = note("Sprint review")
        let paths = OKMeetingPaths.make(project: "p5", startedAt: date, title: n.summary.title)
        let record = OKMeetingRenderer.renderRecord(n, project: "p5", paths: paths)
        try put(record, paths.record, in: vault)
        try put(OKMeetingRenderer.renderTranscript(n, transcript: n.transcript!, project: "p5", paths: paths), paths.transcript, in: vault)
        let p = MeetingProposal(
            recordWritten: true, meetingID: UUID(), note: n, vault: try OKVaultIdentity.of(vault), suggestedProject: "p5",
            project: "p5", paths: paths, fixedPaths: paths, existingRecordHash: textHash(record),
            existingTranscriptHash: text(paths.transcript, in: vault).map(textHash),
            items: [OKProposedItem(action: .update, type: .decisao, path: decisionPath, title: "Usar fila",
                                   markdown: oldADR + "\n## Fontes\n\n- [Sprint review](\(OKPath.relativeLink(from: decisionPath, to: paths.record)))\n",
                                   baseHash: textHash(oldADR), baseContent: oldADR)]
        )
        let dir = try save(p, as: "2026-10-16_143000")
        let recordURL = vault.appendingPathComponent(paths.record)

        let vm = makeVM(dir) { point in
            if point == .afterApply(0) { try? FileManager.default.removeItem(at: recordURL) }
            if case .forwardBeforeRestoreDependency = point { throw Boom() }
        }
        await vm.load()
        vm.approve()
        vm.approve()
        XCTAssertEqual(vm.session?.canCommit, true)
        let ok = await vm.commit()
        XCTAssertFalse(ok)
        XCTAssertTrue(vm.banner?.contains("incompleta") == true, vm.banner ?? "")
        XCTAssertTrue(exists(MeetingProposal.fileName, in: dir))
        XCTAssertTrue(MeetingProposalStore.hasJournal(dir))
        XCTAssertNil(try state(dir).okRecordPath)

        // Reopening without the fault settles the journal first.
        let reopened = makeVM(dir)
        await reopened.load()
        XCTAssertFalse(MeetingProposalStore.hasJournal(dir))
        XCTAssertEqual(text(paths.record, in: vault), record)
        XCTAssertFalse(exists(MeetingProposal.fileName, in: dir))
        XCTAssertEqual(try state(dir).okRecordPath, paths.record)
        XCTAssertEqual(brokenRelativeLinks(vault), [])
    }

    func testPendingFromVaultAIsNotWrittenToVaultB() async throws {
        let vaultA = try makeVault()
        let vaultB = try makeVault()
        let (dir, g1) = try seedManual(vault: vaultA)
        var progress = OKApprovalSession(proposal: g1, progress: nil)
        progress.approve()
        progress.edit("editado")
        progress.approve()
        try progress.progress.save(in: dir)
        try await useVault(vaultB)
        let beforeA = snapshot(vaultA)
        let beforeB = snapshot(vaultB)

        let fake = FakeAssistant()
        let vm = makeVM(dir, assistant: fake)
        await vm.load()
        let stale = makeVM(dir, assistant: fake)
        await stale.load()
        XCTAssertEqual(vm.vaultMismatch?.prepared, try OKVaultIdentity.of(vaultA).root)
        XCTAssertEqual(vm.vaultMismatch?.current, vaultB.path)
        var ok = await vm.commit()
        XCTAssertFalse(ok)
        XCTAssertEqual(snapshot(vaultB), beforeB)

        await vm.prepareForCurrentVault()
        let g2 = try XCTUnwrap(MeetingProposalStore.load(dir))
        XCTAssertNotEqual(g2.generation, g1.generation)
        XCTAssertEqual(g2.vault?.matches(vaultB), true)
        XCTAssertFalse(exists(OKApprovalProgress.fileName, in: dir))
        XCTAssertNil(vm.vaultMismatch)

        let reopened = makeVM(dir, assistant: fake)
        await reopened.load()
        XCTAssertNil(reopened.vaultMismatch)
        XCTAssertEqual(reopened.session?.generation, g2.generation)
        XCTAssertEqual(reopened.session?.current, .project)
        XCTAssertNil(reopened.session?.progress.recordEdit)

        // The window still bound to G1 changes nothing.
        stale.edit("y")
        stale.approve()
        XCTAssertFalse(exists(OKApprovalProgress.fileName, in: dir))
        XCTAssertEqual(MeetingProposalStore.load(dir), g2)
        ok = await stale.commit()
        XCTAssertFalse(ok)
        XCTAssertEqual(snapshot(vaultA), beforeA)
        XCTAssertEqual(snapshot(vaultB), beforeB)
    }

    func testReprocessDuringRebuildKeepsNewestProposal() async throws {
        let vaultA = try makeVault()
        let vaultB = try makeVault()
        let (dir, g1) = try seedManual(vault: vaultA)
        try await useVault(vaultB)
        let gate = Gate()
        let fake = FakeAssistant()
        fake.onSuggest = { await gate.enterAndWait() }
        let vm = makeVM(dir, assistant: fake)
        await vm.load()
        XCTAssertNotNil(vm.vaultMismatch)

        let preparing = Task { await vm.prepareForCurrentVault() }
        await gate.waitEntered()
        var g3 = g1
        g3.generation = UUID()
        g3.vault = try OKVaultIdentity.of(vaultB)
        XCTAssertEqual(try MeetingProposalStore.replaceFromReprocessing(g3, in: dir, builtFrom: try state(dir)) { $0.okProcessed = true }, .replaced)
        await gate.release()
        await preparing.value

        XCTAssertEqual(MeetingProposalStore.load(dir), g3)
        XCTAssertEqual(vm.session?.generation, g3.generation)
        XCTAssertEqual(vm.banner, ApprovalStrings.reprocessed)
        XCTAssertNil(vm.vaultMismatch)
    }
}
