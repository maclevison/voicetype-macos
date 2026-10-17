import Foundation
import Testing
@testable import Core

/// Records every call and answers from canned values.
final class FakeAssistant: OKAssistant, @unchecked Sendable {
    private let lock = NSLock()
    private var _suggestCalls = 0
    private var _planCalls = 0
    private var _writeCalls = 0
    private var _recordPaths: [String] = []

    let suggestion: String?
    let plan: [OKPlannedItem]
    let error: (any Error)?

    init(suggestion: String? = "p5", plan: [OKPlannedItem] = [], error: (any Error)? = nil) {
        self.suggestion = suggestion
        self.plan = plan
        self.error = error
    }

    var suggestCalls: Int { lock.withLock { _suggestCalls } }
    var planCalls: Int { lock.withLock { _planCalls } }
    var writeCalls: Int { lock.withLock { _writeCalls } }
    var totalCalls: Int { suggestCalls + planCalls + writeCalls }
    var recordPaths: [String] { lock.withLock { _recordPaths } }

    func suggestProject(summary: MeetingSummary, projects: [OKProject]) async throws -> String? {
        lock.withLock { _suggestCalls += 1 }
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
        lock.withLock {
            _writeCalls += 1
            _recordPaths.append(recordPath)
        }
        if let error { throw error }
        return plan.map {
            OKProposedItem(action: $0.action, type: $0.type, path: $0.path, title: $0.title,
                           markdown: "---\ntitle: \($0.title)\ndescription: d\ntype: \($0.type.rawValue)\nproject: \(project)\n---\n# \($0.title)\n")
        }
    }
}

@Suite("MeetingProposal")
struct MeetingProposalTests {
    private struct Boom: Error {}

    private let utc = TimeZone(identifier: "UTC")!
    // 2026-10-16 14:30:00 UTC
    private let date = Date(timeIntervalSince1970: 1_792_161_000)
    private let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let fm = FileManager.default

    private func note(title: String = "Sprint review", startedAt: Date? = nil) -> MeetingNote {
        MeetingNote(
            id: id, startedAt: startedAt ?? date, duration: 30 * 60, platform: "teams",
            summary: MeetingSummary(title: title, summary: "Revisamos a sprint.", decisions: ["Usar fila"]),
            transcript: "Você: oi\nOutros: olá"
        )
    }

    private var state: MeetingPipelineState { MeetingPipelineState(noteID: id) }

    private func makeTemp() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, _ relPath: String, in root: URL) throws {
        let url = root.appendingPathComponent(relPath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A vault with `.ok/` and project `p5` holding one decision.
    private func makeVault() throws -> URL {
        let vault = try makeTemp()
        try fm.createDirectory(at: vault.appendingPathComponent(".ok/templates"), withIntermediateDirectories: true)
        try write("---\ntitle: p5\ndescription: Projeto p5.\ntype: indice\nproject: p5\n---\n# p5\n", "p5/index.md", in: vault)
        try write("---\ntitle: Usar X\ndescription: Decidimos X.\ntype: decisao\nproject: p5\n---\nX\n", "p5/decisoes/usar-x.md", in: vault)
        return vault
    }

    private let newDecision = OKPlannedItem(action: .new, type: .decisao, path: "p5/decisoes/usar-fila.md", title: "Usar fila", reason: "decidido")

    private func builder(_ assistant: (any OKAssistant)?) -> OKProposalBuilder {
        OKProposalBuilder(assistant: assistant, user: "Mac", timeZone: utc)
    }

    private func proposal(generation: UUID = UUID(), title: String = "Sprint review", startedAt: Date? = nil) -> MeetingProposal {
        MeetingProposal(generation: generation, meetingID: id, note: note(title: title, startedAt: startedAt))
    }

    private func distilledItem() -> OKProposedItem {
        OKProposedItem(action: .new, type: .decisao, path: "p5/decisoes/usar-fila.md", title: "Usar fila", markdown: "x")
    }

    // MARK: - Builder

    @Test func buildDistillsAgainstSuggestedProject() async throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        let fake = FakeAssistant(suggestion: "p5", plan: [newDecision])

        let p = await builder(fake).build(note: note(), summaryFailure: nil, state: state, vault: vault, now: date)

        #expect(p.meetingID == id)
        #expect(p.suggestedProject == "p5")
        #expect(p.project == "p5")
        #expect(p.items.count == 1)
        #expect(p.items.first?.path == "p5/decisoes/usar-fila.md")
        #expect(p.catalogFingerprint == OKVaultCatalog.fingerprint(try OKVaultCatalog.docs(project: "p5", in: vault)))
        #expect(p.distilledAt == date)
        #expect(p.distillationError == nil)
        #expect(p.fixedPaths == nil)
        #expect(!p.recordWritten)
        #expect(fake.suggestCalls == 1 && fake.planCalls == 1 && fake.writeCalls == 1)
    }

    @Test func buildWithoutSuggestionHasNoProjectNorItems() async throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        let fake = FakeAssistant(suggestion: nil, plan: [newDecision])

        let p = await builder(fake).build(note: note(), summaryFailure: nil, state: state, vault: vault, now: date)

        #expect(p.suggestedProject == nil)
        #expect(p.project == nil)
        #expect(p.items.isEmpty)
        #expect(p.distillationError == nil)
        #expect(fake.planCalls == 0 && fake.writeCalls == 0)
    }

    @Test func summaryFailureMakesRecordOnlyProposal() async throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        let fake = FakeAssistant(suggestion: "p5", plan: [newDecision])

        let p = await builder(fake).build(note: note(), summaryFailure: "x", state: state, vault: vault, now: date)

        #expect(p.summaryFailure == "x")
        #expect(p.items.isEmpty)
        #expect(p.suggestedProject == nil)
        #expect(p.distilledAt == nil)
        #expect(fake.totalCalls == 0)
    }

    @Test func approvedMeetingKeepsFixedPathsAndHashes() async throws {
        let vault = try makeVault()
        let other = try makeVault()
        defer { try? fm.removeItem(at: vault); try? fm.removeItem(at: other) }
        let record = "p5/reunioes/2026-10-16-a.md"
        let transcript = "p5/reunioes/transcricoes/2026-10-16-a.md"
        try write("---\nid: \(id.uuidString)\n---\nregistro\n", record, in: vault)

        var approved = state
        approved.okVault = try OKVaultIdentity.of(vault)
        approved.okProject = "p5"
        approved.okRecordPath = record
        approved.okTranscriptPath = transcript

        let fake = FakeAssistant(suggestion: "outro", plan: [newDecision])
        let p = await builder(fake).build(note: note(), summaryFailure: nil, state: approved, vault: vault, now: date)

        #expect(p.fixedPaths == OKMeetingPaths(record: record, transcript: transcript))
        #expect(p.paths == p.fixedPaths)
        #expect(p.project == "p5" && p.suggestedProject == "p5")
        #expect(p.existingRecordHash == OKPath.contentHash(try Data(contentsOf: vault.appendingPathComponent(record))))
        #expect(p.existingTranscriptHash == nil)
        #expect(fake.suggestCalls == 0)
        #expect(fake.recordPaths == [record])

        approved.okVault = try OKVaultIdentity.of(other)
        let fake2 = FakeAssistant(suggestion: "p5", plan: [newDecision])
        let q = await builder(fake2).build(note: note(), summaryFailure: nil, state: approved, vault: vault, now: date)
        #expect(q.fixedPaths == nil)
        #expect(q.existingRecordHash == nil)
        #expect(fake2.suggestCalls == 1)
    }

    @Test func approvedMeetingWithSummaryFailureKeepsFixedPathsWithoutModel() async throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        var approved = state
        approved.okVault = try OKVaultIdentity.of(vault)
        approved.okProject = "p5"
        approved.okRecordPath = "p5/reunioes/2026-10-16-a.md"
        approved.okTranscriptPath = "p5/reunioes/transcricoes/2026-10-16-a.md"
        let fake = FakeAssistant()

        let p = await builder(fake).build(note: note(), summaryFailure: "x", state: approved, vault: vault, now: date)

        #expect(p.fixedPaths?.record == "p5/reunioes/2026-10-16-a.md")
        #expect(p.project == "p5")
        #expect(p.items.isEmpty)
        #expect(fake.totalCalls == 0)
    }

    @Test func proposalPersistsVaultAndPathsUsedForDistillation() async throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        // Another meeting already holds the plain name: this one moves to -2.
        try write("---\nid: \(UUID().uuidString)\n---\n", "p5/reunioes/2026-10-16-sprint-review.md", in: vault)
        let fake = FakeAssistant(suggestion: "p5", plan: [newDecision])

        let p = await builder(fake).build(note: note(), summaryFailure: nil, state: state, vault: vault, now: date)

        #expect(p.vault == (try OKVaultIdentity.of(vault)))
        #expect(p.paths?.record == "p5/reunioes/2026-10-16-sprint-review-2.md")
        #expect(fake.recordPaths == [p.paths?.record])

        let decoded = try MeetingProposalStore.decode(MeetingProposalStore.encode(p))
        #expect(decoded == p)
    }

    @Test func assistantErrorStillCreatesPending() async throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }

        let p = await builder(FakeAssistant(error: Boom())).build(note: note(), summaryFailure: nil, state: state, vault: vault, now: date)
        #expect(p.distillationError != nil)
        #expect(p.items.isEmpty)
        #expect(p.vault != nil)

        let missing = await builder(nil).build(note: note(), summaryFailure: nil, state: state, vault: vault, now: date)
        #expect(missing.distillationError == "Claude CLI não encontrado")
        #expect(missing.items.isEmpty)

        let invalid = try makeTemp()
        defer { try? fm.removeItem(at: invalid) }
        let fake = FakeAssistant()
        let q = await builder(fake).build(note: note(), summaryFailure: nil, state: state, vault: invalid, now: date)
        #expect(q.vault == nil)
        #expect(q.distillationError != nil)
        #expect(q.items.isEmpty)
        #expect(fake.totalCalls == 0)
    }

    @Test func redistillKeepsGenerationAndRecomputesPaths() async throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        try write("---\ntitle: acme\ntype: indice\n---\n", "acme/index.md", in: vault)
        let fake = FakeAssistant(suggestion: "p5", plan: [OKPlannedItem(action: .new, type: .gotcha, path: "acme/gotchas/g.md", title: "G", reason: "r")])
        let start = proposal()

        let p = try await builder(fake).redistill(start, project: "acme", vault: vault, now: date)

        #expect(p.generation == start.generation)
        #expect(p.project == "acme")
        #expect(p.paths?.record == "acme/reunioes/2026-10-16-sprint-review.md")
        #expect(fake.recordPaths == [p.paths?.record])
        #expect(p.items.map(\.path) == ["acme/gotchas/g.md"])
        #expect(p.distilledAt == date)

        await #expect(throws: (any Error).self) {
            _ = try await builder(FakeAssistant(error: Boom())).redistill(start, project: "p5", vault: vault, now: date)
        }
    }

    @Test func rebuildMakesNewGenerationForCurrentVault() async throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        var start = proposal()
        start.summaryFailure = "x"

        let p = await builder(FakeAssistant()).rebuild(start, state: state, vault: vault, now: date)

        #expect(p.generation != start.generation)
        #expect(p.note == start.note)
        #expect(p.summaryFailure == "x")
        #expect(p.vault == (try OKVaultIdentity.of(vault)))
    }

    @Test func staleAfter24hOrCatalogChange() {
        var p = proposal()
        p.items = [distilledItem()]
        p.catalogFingerprint = "f"
        p.distilledAt = date.addingTimeInterval(-25 * 3600)
        #expect(OKProposalBuilder.isStale(p, currentFingerprint: "f", now: date))

        p.distilledAt = date.addingTimeInterval(-3600)
        #expect(OKProposalBuilder.isStale(p, currentFingerprint: "g", now: date))
        #expect(!OKProposalBuilder.isStale(p, currentFingerprint: "f", now: date))
    }

    @Test func staleOnlyWithDistilledItems() {
        var p = proposal()
        p.summaryFailure = "x"
        #expect(!OKProposalBuilder.isStale(p, currentFingerprint: "qualquer", now: date.addingTimeInterval(25 * 3600)))

        var empty = proposal()
        empty.catalogFingerprint = "f"
        empty.distilledAt = date.addingTimeInterval(-25 * 3600)
        #expect(!OKProposalBuilder.isStale(empty, currentFingerprint: "g", now: date))
    }

    @Test func repathChangesProjectWithoutModel() throws {
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        let fake = FakeAssistant()
        _ = builder(fake) // never called by repath
        var start = proposal()
        start.summaryFailure = "x"
        start.items = [distilledItem()]
        start.distilledAt = date
        start.catalogFingerprint = "f"

        let p = OKProposalBuilder.repath(start, project: "p5", vault: vault, timeZone: utc)
        #expect(p.project == "p5")
        #expect(p.paths?.record == "p5/reunioes/2026-10-16-sprint-review.md")
        #expect(p.paths?.transcript == "p5/reunioes/transcricoes/2026-10-16-sprint-review.md")
        #expect(p.items.isEmpty && p.distilledAt == nil && p.catalogFingerprint == nil)
        #expect(p.generation == start.generation)
        #expect(p.summaryFailure == "x" && p.note == start.note && p.suggestedProject == nil)

        let acme = OKProposalBuilder.repath(start, project: "acme", vault: vault, timeZone: utc)
        #expect(acme.paths?.record.hasPrefix("acme/reunioes/") == true)
        #expect(fake.totalCalls == 0)
    }

    // MARK: - Store

    private func journal(in dir: URL) throws {
        try write("{}", "ok-commit/journal.json", in: dir)
    }

    private func progressURL(_ dir: URL) -> URL { dir.appendingPathComponent(MeetingProposalStore.progressFileName) }
    private func proposalURL(_ dir: URL) -> URL { dir.appendingPathComponent(MeetingProposal.fileName) }

    /// Writes a proposal straight to disk, as the processor's first run does.
    private func seed(_ p: MeetingProposal, in dir: URL) throws {
        try MeetingProposalStore.encode(p).write(to: proposalURL(dir))
    }

    @Test func storeRoundTripAndPendingScan() throws {
        let base = try makeTemp()
        defer { try? fm.removeItem(at: base) }
        let older = base.appendingPathComponent("2026-10-15-0900", isDirectory: true)
        let newer = base.appendingPathComponent("2026-10-16-1430", isDirectory: true)
        let none = base.appendingPathComponent("2026-10-16-1500", isDirectory: true)
        for dir in [older, newer, none] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        let a = proposal(title: "Antiga", startedAt: date.addingTimeInterval(-86_400))
        let b = proposal(title: "Nova")
        try seed(a, in: older)
        try seed(b, in: newer)
        #expect(MeetingProposalStore.load(newer) == b)
        #expect(MeetingProposalStore.load(none) == nil)

        let pending = PendingMeetings.scan(base: base)
        #expect(pending.map(\.id) == ["2026-10-16-1430", "2026-10-15-0900"])
        #expect(pending.map(\.generation) == [b.generation, a.generation])
        #expect(pending.map(\.title) == ["Nova", "Antiga"])
        #expect(pending.first?.directory.lastPathComponent == "2026-10-16-1430")
        #expect(pending.first?.startedAt == date)

        try write("{}", MeetingProposalStore.progressFileName, in: newer)
        MeetingProposalStore.remove(newer, generation: UUID())
        #expect(fm.fileExists(atPath: proposalURL(newer).path))
        #expect(fm.fileExists(atPath: progressURL(newer).path))

        MeetingProposalStore.remove(newer, generation: b.generation)
        #expect(!fm.fileExists(atPath: proposalURL(newer).path))
        #expect(!fm.fileExists(atPath: progressURL(newer).path))

        try write("{}", MeetingProposalStore.progressFileName, in: older)
        MeetingProposalStore.remove(older)
        #expect(!fm.fileExists(atPath: proposalURL(older).path))
        #expect(!fm.fileExists(atPath: progressURL(older).path))
        #expect(PendingMeetings.scan(base: base).isEmpty)
    }

    @Test func saveRefusesOtherGeneration() throws {
        let dir = try makeTemp()
        defer { try? fm.removeItem(at: dir) }
        var p1 = proposal()
        p1.project = "p5"
        #expect(throws: MeetingProposalStore.StoreError.generationChanged) { try MeetingProposalStore.save(p1, in: dir) }
        #expect(!fm.fileExists(atPath: proposalURL(dir).path))

        let p2 = proposal()
        try seed(p2, in: dir)
        let before = try Data(contentsOf: proposalURL(dir))
        #expect(throws: MeetingProposalStore.StoreError.generationChanged) { try MeetingProposalStore.save(p1, in: dir) }
        #expect(try Data(contentsOf: proposalURL(dir)) == before)

        var edited = p2
        edited.project = "acme"
        try MeetingProposalStore.save(edited, in: dir)
        #expect(MeetingProposalStore.load(dir) == edited)
    }

    @Test func replaceExpectingOldGeneration() throws {
        let dir = try makeTemp()
        defer { try? fm.removeItem(at: dir) }
        let g1 = proposal()
        let g2 = proposal()
        try seed(g1, in: dir)
        try write("{}", MeetingProposalStore.progressFileName, in: dir)

        try MeetingProposalStore.replace(g2, in: dir, expecting: g1.generation)
        #expect(MeetingProposalStore.load(dir) == g2)
        #expect(!fm.fileExists(atPath: progressURL(dir).path))
        var edited = g1
        edited.project = "p5"
        #expect(throws: MeetingProposalStore.StoreError.generationChanged) { try MeetingProposalStore.save(edited, in: dir) }

        let g3 = proposal()
        try seed(g3, in: dir)
        #expect(throws: MeetingProposalStore.StoreError.generationChanged) { try MeetingProposalStore.replace(g2, in: dir, expecting: g1.generation) }
        #expect(MeetingProposalStore.load(dir) == g3)

        try journal(in: dir)
        try write("{}", MeetingProposalStore.progressFileName, in: dir)
        #expect(throws: MeetingProposalStore.StoreError.meetingBusy) { try MeetingProposalStore.replace(g2, in: dir, expecting: g3.generation) }
        #expect(MeetingProposalStore.load(dir) == g3)
        #expect(fm.fileExists(atPath: progressURL(dir).path))
    }

    private func writeState(_ s: MeetingPipelineState, in dir: URL) throws {
        try JSONEncoder().encode(s).write(to: dir.appendingPathComponent(MeetingPipelineState.stateFileName))
    }

    private func readState(_ dir: URL) throws -> MeetingPipelineState {
        try JSONDecoder().decode(MeetingPipelineState.self, from: Data(contentsOf: dir.appendingPathComponent(MeetingPipelineState.stateFileName)))
    }

    @Test func replaceFromReprocessingRefusesBusyOrApprovedMeeting() throws {
        let dir = try makeTemp()
        defer { try? fm.removeItem(at: dir) }
        let old = proposal()
        let new = proposal()
        try seed(old, in: dir)
        try write("{\"progress\":1}", MeetingProposalStore.progressFileName, in: dir)
        let inMemory = MeetingPipelineState(noteID: id, transcriptPath: "/tmp/t.md")
        try writeState(inMemory, in: dir)
        let update: (inout MeetingPipelineState) -> Void = { $0.okProcessed = true; $0.summarized = true }

        // Busy: a journal is there.
        try journal(in: dir)
        #expect(try MeetingProposalStore.replaceFromReprocessing(new, in: dir, builtFrom: inMemory, update: update) == .meetingBusy)
        #expect(MeetingProposalStore.load(dir) == old)
        #expect(try String(contentsOf: progressURL(dir), encoding: .utf8) == "{\"progress\":1}")
        #expect(try readState(dir) == inMemory)
        try fm.removeItem(at: dir.appendingPathComponent("ok-commit"))

        // Approved while processing: the disk already has a record path.
        let vault = try makeVault()
        defer { try? fm.removeItem(at: vault) }
        var approved = inMemory
        approved.okVault = try OKVaultIdentity.of(vault)
        approved.okProject = "p5"
        approved.okRecordPath = "p5/reunioes/2026-10-16-a.md"
        approved.okTranscriptPath = "p5/reunioes/transcricoes/2026-10-16-a.md"
        try writeState(approved, in: dir)
        #expect(try MeetingProposalStore.replaceFromReprocessing(new, in: dir, builtFrom: inMemory, update: update) == .approvedMeanwhile)
        #expect(MeetingProposalStore.load(dir) == old)
        #expect(fm.fileExists(atPath: progressURL(dir).path))
        #expect(try readState(dir) == approved)

        // Free: built from the approved state, nothing changed since.
        #expect(try MeetingProposalStore.replaceFromReprocessing(new, in: dir, builtFrom: approved, update: update) == .replaced)
        #expect(MeetingProposalStore.load(dir) == new)
        #expect(!fm.fileExists(atPath: progressURL(dir).path))
        var expected = approved
        expected.okProcessed = true
        expected.summarized = true
        #expect(try readState(dir) == expected)
    }

    @Test func replaceFromReprocessingAppliesUpdateOverDiskState() throws {
        let dir = try makeTemp()
        defer { try? fm.removeItem(at: dir) }
        let built = MeetingPipelineState(noteID: id)
        var disk = built
        disk.transcriptPath = "/tmp/t.md"
        try writeState(disk, in: dir)

        #expect(try MeetingProposalStore.replaceFromReprocessing(proposal(), in: dir, builtFrom: built) { $0.okProcessed = true } == .replaced)
        var expected = disk
        expected.okProcessed = true
        #expect(try readState(dir) == expected)
    }

    @Test func pipelineStateDecodesLegacyJSON() throws {
        let json = #"{"noteID":"11111111-2222-3333-4444-555555555555","summarized":true}"#
        let s = try JSONDecoder().decode(MeetingPipelineState.self, from: Data(json.utf8))
        #expect(s.noteID == id)
        #expect(s.summarized)
        #expect(s.okVault == nil && s.okProject == nil && s.okRecordPath == nil && s.okTranscriptPath == nil && s.okProcessed == nil)

        let legacy = try JSONEncoder().encode(MeetingPipelineState(noteID: id, summarized: true))
        #expect(!String(decoding: legacy, as: UTF8.self).contains("ok"))
    }
}
