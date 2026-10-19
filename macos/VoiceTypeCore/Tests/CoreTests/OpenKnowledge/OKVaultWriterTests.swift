import Foundation
import Testing
@testable import Core

// MARK: - Helpers (free functions, so the @Sendable fault hooks can call them)

private struct Boom: Error {}

/// A descriptor a test holds like an editor would; `move` dups it to a new
/// number and closes the old one, as a process shuffling its descriptors.
private final class Descriptor: @unchecked Sendable {
    private(set) var fd: Int32
    init(_ fd: Int32) { self.fd = fd }
    func move() {
        let moved = dup(fd)
        Darwin.close(fd)
        fd = moved
    }
    func close() { if fd >= 0 { Darwin.close(fd) } }
}

private func h(_ text: String) -> String { OKPath.contentHash(Data(text.utf8)) }

/// An outside write: in place, like an editor saving.
private func put(_ vault: URL, _ path: String, _ text: String) throws {
    let url = vault.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private func del(_ vault: URL, _ path: String) throws {
    try FileManager.default.removeItem(at: vault.appendingPathComponent(path))
}

private func text(_ vault: URL, _ path: String) -> String? {
    contents(vault.appendingPathComponent(path).path)
}

private func contents(_ absolutePath: String) -> String? {
    (try? Data(contentsOf: URL(fileURLWithPath: absolutePath))).map { String(decoding: $0, as: UTF8.self) }
}

/// Every file and folder of the vault outside `.ok/local/`, with its bytes.
private func snapshot(_ vault: URL) -> [String: Data] {
    var out: [String: Data] = [:]
    let enumerator = FileManager.default.enumerator(atPath: vault.path)
    while let rel = enumerator?.nextObject() as? String {
        if rel == ".ok/local" || rel.hasPrefix(".ok/local/") { continue }
        var isDirectory: ObjCBool = false
        let url = vault.appendingPathComponent(rel)
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        out[rel] = isDirectory.boolValue ? Data("<dir>".utf8) : (try? Data(contentsOf: url)) ?? Data()
    }
    return out
}

private func stagingRoot(_ vault: URL) -> URL {
    vault.appendingPathComponent(".ok/local/voicetype-staging", isDirectory: true)
}

private func stagingEntries(_ vault: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot(vault).path)) ?? []
}

/// A file of the (single) transaction staging folder.
private func staged(_ vault: URL, _ name: String) -> String? {
    guard let txid = stagingEntries(vault).first else { return nil }
    return contents(stagingRoot(vault).appendingPathComponent(txid).appendingPathComponent(name).path)
}

private func phase(_ journal: URL) throws -> OKVaultWriter.Journal.Phase? {
    try OKVaultWriter.Journal.load(from: journal)?.phase
}

/// Every relative Markdown link, and the `transcript`/`meeting` frontmatter
/// fields, of every `.md` outside hidden folders must resolve to a file.
private func brokenRelativeLinks(_ vault: URL) -> [String] {
    let link = try! NSRegularExpression(pattern: #"\]\(([^)\s]+)\)"#)
    let field = try! NSRegularExpression(pattern: #"(?m)^(?:transcript|meeting): "([^"]+)"$"#)
    var broken: [String] = []
    let enumerator = FileManager.default.enumerator(atPath: vault.path)
    while let rel = enumerator?.nextObject() as? String {
        guard rel.hasSuffix(".md"), !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
        let body = text(vault, rel) ?? ""
        let ns = body as NSString
        let range = NSRange(location: 0, length: ns.length)
        let targets = (link.matches(in: body, range: range) + field.matches(in: body, range: range))
            .map { ns.substring(with: $0.range(at: 1)) }
        let dir = vault.appendingPathComponent(rel).deletingLastPathComponent()
        for target in targets where !target.contains("://") && !target.hasPrefix("#") && !target.hasPrefix("mailto:") {
            let file = String(target.split(separator: "#", omittingEmptySubsequences: false)[0])
            if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).standardizedFileURL.path) {
                broken.append("\(rel) -> \(target)")
            }
        }
    }
    return broken
}

private func receiptOf(_ result: OKCommitResult) -> OKCommitReceipt? {
    if case let .committed(receipt) = result { return receipt }
    return nil
}

private func receiptOf(_ outcome: OKRecoveryOutcome) -> OKCommitReceipt? {
    if case let .committed(receipt) = outcome { return receipt }
    return nil
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

/// Real meeting files: record ↔ transcript, record → knowledge docs
/// ("Conhecimento destilado"), docs → record ("Fontes"), index → doc.
private struct MeetingFixture {
    static let utc = TimeZone(identifier: "UTC")!
    let note: MeetingNote
    let paths: OKMeetingPaths
    let adrPath = "p5/decisoes/usar-x.md"
    let adr2Path = "p5/decisoes/usar-y.md"
    let gotchaPath = "p5/gotchas/g.md"
    let indexPath = "p5/index.md"
    let metadataPath = "p5/reunioes/.ok/frontmatter.yml"
    let indexOld = "# p5\n"

    init() {
        let date = Date(timeIntervalSince1970: 1_792_161_000)
        note = MeetingNote(
            startedAt: date, duration: 1800,
            summary: MeetingSummary(title: "Sprint review", summary: "Revisamos a sprint."),
            transcript: "Você: oi\nOutro 1: olá"
        )
        paths = OKMeetingPaths.make(project: "p5", startedAt: date, title: "Sprint review", timeZone: Self.utc)
    }

    var transcript: String {
        OKMeetingRenderer.renderTranscript(note, transcript: note.transcript ?? "", project: "p5", paths: paths, timeZone: Self.utc)
    }

    func record(linking docs: [String]) -> String {
        OKMeetingRenderer.appendingDistilled(
            docs.map { OKDistilledLink(title: "Doc \($0)", path: $0) },
            to: OKMeetingRenderer.renderRecord(note, project: "p5", paths: paths, timeZone: Self.utc),
            paths: paths
        )
    }

    /// A knowledge doc whose "## Fontes" links the record.
    func knowledge(_ path: String, base: String = "---\ntitle: \"Doc\"\n---\n\n# Doc\n") -> String {
        base + "\n## Fontes\n\n- [Sprint review](\(OKPath.relativeLink(from: path, to: paths.record)))\n"
    }

    var indexNew: String {
        indexOld + "\n- [Usar X](\(OKPath.relativeLink(from: indexPath, to: adrPath)))\n"
    }

    static func edited(_ text: String) -> String { text + "\nEditado no OpenKnowledge.\n" }
}

/// Serialized: every test blocks its thread on `F_FULLFSYNC`, and 28 of them at once
/// starve the cooperative pool that the timing-based suites (AppStateMachine) need.
@Suite("OKVaultWriter", .serialized)
struct OKVaultWriterTests {
    private func makeVault(_ files: [String: String] = [:]) throws -> URL {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".ok", isDirectory: true), withIntermediateDirectories: true)
        for (path, content) in files { try put(vault, path, content) }
        return vault
    }

    private func newJournal() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("ok-commit", isDirectory: true)
    }

    private func makeWriter(_ vault: URL, _ journal: URL) throws -> OKVaultWriter {
        OKVaultWriter(vault: vault, identity: try OKVaultIdentity.of(vault), journalDirectory: journal)
    }

    private func receipt(_ vault: URL, paths: OKMeetingPaths? = nil) throws -> OKCommitReceipt {
        OKCommitReceipt(
            meetingID: UUID(), proposalGeneration: UUID(), vault: try OKVaultIdentity.of(vault), project: "p5",
            paths: paths ?? OKMeetingPaths(record: "p5/reunioes/r.md", transcript: "p5/reunioes/transcricoes/r.md")
        )
    }

    /// create a.md, update b.md ("A\n" → "B\n"), create sub/c.md.
    private let threeOps: [OKVaultOp] = [
        .create(path: "a.md", content: "NA\n", itemID: nil),
        .update(path: "b.md", content: "B\n", expectedHash: h("A\n"), itemID: nil),
        .create(path: "sub/c.md", content: "NC\n", itemID: nil),
    ]

    /// transcript, record (→ ADR), ADR (→ record), index (→ ADR), with the
    /// folder metadata first when `metadata`.
    private func meetingOps(_ m: MeetingFixture, adrItem: UUID? = nil, metadata: Bool = false) -> [OKVaultOp] {
        (metadata ? [.createIfMissing(path: m.metadataPath, content: "title: Reuniões\n")] : []) + [
            .create(path: m.paths.transcript, content: m.transcript, itemID: nil),
            .create(path: m.paths.record, content: m.record(linking: [m.adrPath]), itemID: nil),
            .create(path: m.adrPath, content: m.knowledge(m.adrPath), itemID: adrItem),
            .update(path: m.indexPath, content: m.indexNew, expectedHash: h(m.indexOld), itemID: nil),
        ]
    }

    /// transcript, record (→ ADR), update of the existing ADR ("A\n" → N with "## Fontes").
    private func updateADROps(_ m: MeetingFixture, adrItem: UUID? = nil) -> [OKVaultOp] {
        [
            .create(path: m.paths.transcript, content: m.transcript, itemID: nil),
            .create(path: m.paths.record, content: m.record(linking: [m.adrPath]), itemID: nil),
            .update(path: m.adrPath, content: m.knowledge(m.adrPath, base: "A\n"), expectedHash: h("A\n"), itemID: adrItem),
        ]
    }

    // MARK: Normal path and validation

    @Test func commitsCreatesUpdatesAndSkipsExistingMetadata() throws {
        let vault = try makeVault(["p5/index.md": "# p5\n", "p5/reunioes/.ok/frontmatter.yml": "title: Meu\n"])
        let before = Set(snapshot(vault).keys)
        let journal = newJournal()
        let writer = try makeWriter(vault, journal)

        let result = try writer.commit([
            .createIfMissing(path: "p5/reunioes/.ok/frontmatter.yml", content: "title: Reuniões\n"),
            .create(path: "p5/reunioes/a.md", content: "A\n", itemID: UUID()),
            .update(path: "p5/index.md", content: "# p5\n- a\n", expectedHash: h("# p5\n"), itemID: nil),
        ], receipt: try receipt(vault), precondition: { true })

        let r = try #require(receiptOf(result))
        #expect(r.written == ["p5/reunioes/a.md", "p5/index.md"])
        #expect(text(vault, "p5/reunioes/a.md") == "A\n")
        #expect(text(vault, "p5/index.md") == "# p5\n- a\n")
        #expect(text(vault, "p5/reunioes/.ok/frontmatter.yml") == "title: Meu\n")
        #expect(Set(snapshot(vault).keys) == before.union(["p5/reunioes/a.md"]))
        #expect(try phase(journal) == .committed)

        #expect(try OKVaultWriter.finish(journalDirectory: journal) == [])
        #expect(stagingEntries(vault).isEmpty)
        #expect(try phase(journal) == nil)
    }

    @Test func changedHashIsConflictAndWritesNothing() throws {
        let vault = try makeVault(["b.md": "X\n"])
        let journal = newJournal()
        let item = UUID()
        let result = try makeWriter(vault, journal).commit([
            .create(path: "a.md", content: "A\n", itemID: nil),
            .update(path: "b.md", content: "B\n", expectedHash: h("old\n"), itemID: item),
        ], receipt: try receipt(vault), precondition: { true })

        #expect(result == .conflicts([OKConflict(itemID: item, path: "b.md", currentContent: "X\n", currentHash: h("X\n"))], divergences: []))
        #expect(text(vault, "a.md") == nil)
        #expect(text(vault, "b.md") == "X\n")
        #expect(!FileManager.default.fileExists(atPath: stagingRoot(vault).path))
        #expect(try phase(journal) == nil)
    }

    @Test func createOverExistingFileIsConflict() throws {
        let vault = try makeVault(["a.md": "existente\n"])
        let journal = newJournal()
        let item = UUID()
        let result = try makeWriter(vault, journal).commit(
            [.create(path: "a.md", content: "novo\n", itemID: item)], receipt: try receipt(vault), precondition: { true }
        )

        #expect(result == .conflicts([OKConflict(itemID: item, path: "a.md", currentContent: "existente\n", currentHash: h("existente\n"))], divergences: []))
        #expect(text(vault, "a.md") == "existente\n")
        #expect(stagingEntries(vault).isEmpty)
        #expect(try phase(journal) == nil)
    }

    @Test func preconditionFalseWritesNothing() throws {
        let vault = try makeVault(["b.md": "A\n"])
        let original = snapshot(vault)
        let journal = newJournal()
        let result = try makeWriter(vault, journal).commit(threeOps, receipt: try receipt(vault), precondition: { false })

        #expect(result == .preconditionFailed)
        #expect(snapshot(vault) == original)
        #expect(stagingEntries(vault).isEmpty)
        #expect(try phase(journal) == nil)
    }

    @Test func stagingNeverLandsInContentFolders() throws {
        let m = MeetingFixture()
        let vault = try makeVault([m.indexPath: m.indexOld])
        let original = Set(snapshot(vault).keys)
        let seen = Box<Set<String>?>(nil)
        let stagedCount = Box(0)
        var writer = try makeWriter(vault, newJournal())
        writer.fault = { point in
            guard point == .afterPrepare else { return }
            seen.value = Set(snapshot(vault).keys)
            stagedCount.value = stagingEntries(vault).count
        }
        _ = try writer.commit(meetingOps(m, metadata: true), receipt: try receipt(vault, paths: m.paths), precondition: { true })

        #expect(seen.value == original)
        #expect(stagedCount.value == 1)
    }

    @Test func rejectsTraversalSymlinkEscapeAndOtherVault() throws {
        let vault = try makeVault(["p5/index.md": "# p5\n"])
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try put(outside, "alvo.md", "fora\n")
        try FileManager.default.createSymbolicLink(at: vault.appendingPathComponent("p5/link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: vault.appendingPathComponent("p5/s.md"), withDestinationURL: outside.appendingPathComponent("alvo.md"))
        let original = snapshot(vault)
        let writer = try makeWriter(vault, newJournal())
        let r = try receipt(vault)

        for path in ["../fora.md", "p5/../../fora.md", "/abs.md", "p5//x.md", "p5/x.txt", ".ok/local/x.md", "p5/link/x.md"] {
            #expect(throws: OKVaultWriter.WriteError.invalidPath(path)) {
                try writer.commit([.create(path: path, content: "x\n", itemID: nil)], receipt: r, precondition: { true })
            }
        }
        #expect(throws: OKVaultWriter.WriteError.invalidPath("p5/s.md")) {
            try writer.commit([.update(path: "p5/s.md", content: "x\n", expectedHash: h("fora\n"), itemID: nil)], receipt: r, precondition: { true })
        }

        let other = try makeVault()
        let foreign = OKVaultWriter(vault: vault, identity: try OKVaultIdentity.of(other), journalDirectory: newJournal())
        #expect(throws: OKVaultWriter.WriteError.vaultMismatch) {
            try foreign.commit([.create(path: "p5/a.md", content: "x\n", itemID: nil)], receipt: r, precondition: { true })
        }

        #expect(snapshot(vault) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["alvo.md"])
        #expect(text(outside, "alvo.md") == "fora\n")
        #expect(stagingEntries(vault).isEmpty)
    }

    // MARK: Outside edits during the commit

    @Test func externalEditBetweenCheckAndApplyIsPreserved() throws {
        let vault = try makeVault(["b.md": "A\n"])
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { point in
            if point == .beforeApply(1) { try put(vault, "b.md", "EXTERNO\n") }
        }
        let item = UUID()
        let result = try writer.commit([
            .create(path: "a.md", content: "NA\n", itemID: nil),
            .update(path: "b.md", content: "B\n", expectedHash: h("A\n"), itemID: item),
        ], receipt: try receipt(vault), precondition: { true })

        #expect(result == .conflicts([OKConflict(itemID: item, path: "b.md", currentContent: "EXTERNO\n", currentHash: h("EXTERNO\n"))], divergences: []))
        #expect(text(vault, "b.md") == "EXTERNO\n")
        #expect(text(vault, "a.md") == nil)
        #expect(stagingEntries(vault).isEmpty)
        #expect(try phase(journal) == nil)
    }

    @Test func externalEditAfterApplyIsKeptAndTransactionCompletes() throws {
        let vault = try makeVault(["b.md": "A\n"])
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { point in
            switch point {
            case .afterApply(0): try put(vault, "a.md", "EXTERNO\n")
            case .beforeApply(2): throw Boom()
            default: break
            }
        }
        let result = try writer.commit(threeOps, receipt: try receipt(vault), precondition: { true })

        #expect(receiptOf(result)?.written == ["a.md", "b.md", "sub/c.md"])
        #expect(text(vault, "a.md") == "EXTERNO\n")
        #expect(text(vault, "b.md") == "B\n")
        #expect(text(vault, "sub/c.md") == "NC\n")
        #expect(try phase(journal) == .committed)
    }

    @Test func identicalDestinationForcesCompletion() throws {
        let vault = try makeVault()
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { point in
            if point == .beforeApply(1) {
                try put(vault, "b.md", "B\n")
                throw Boom()
            }
        }
        let result = try writer.commit([
            .create(path: "a.md", content: "[b](b.md)\n", itemID: nil),
            .create(path: "b.md", content: "B\n", itemID: nil),
        ], receipt: try receipt(vault), precondition: { true })

        #expect(receiptOf(result) != nil)
        #expect(text(vault, "a.md") == "[b](b.md)\n")
        #expect(text(vault, "b.md") == "B\n")
        #expect(brokenRelativeLinks(vault) == [])
    }

    // MARK: Completion with real meeting files

    @Test func foreignEditOfRecordThenLaterFailureCompletesWithoutBrokenLinks() throws {
        let m = MeetingFixture()
        let externalRecord = MeetingFixture.edited(m.record(linking: [m.adrPath]))
        let vault = try makeVault([m.indexPath: m.indexOld])
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { point in
            switch point {
            case .afterApply(2): try put(vault, m.paths.record, externalRecord)
            case .beforeApply(3): throw OKSimulatedCrash()
            default: break
            }
        }
        let ops = meetingOps(m, metadata: true)
        let r = try receipt(vault, paths: m.paths)
        #expect(throws: OKSimulatedCrash.self) { try writer.commit(ops, receipt: r, precondition: { true }) }

        #expect(throws: OKSimulatedCrash.self) {
            try OKVaultWriter.recover(journalDirectory: journal, fault: { if $0 == .forwardBeforeApply(3) { throw OKSimulatedCrash() } })
        }
        #expect(try phase(journal) == .rollingForward)

        let outcome = try OKVaultWriter.recover(journalDirectory: journal)
        #expect(receiptOf(outcome)?.written == ops.map(\.path))
        #expect(text(vault, m.paths.record) == externalRecord)
        #expect(text(vault, m.paths.transcript) == m.transcript)
        #expect(text(vault, m.adrPath) == m.knowledge(m.adrPath))
        #expect(text(vault, m.indexPath) == m.indexNew)
        #expect(text(vault, m.metadataPath) == "title: Reuniões\n")
        #expect(brokenRelativeLinks(vault) == [])

        let settled = snapshot(vault)
        #expect(try OKVaultWriter.recover(journalDirectory: journal) == outcome)
        #expect(snapshot(vault) == settled)

        // Same sequence without a crash: the failure is an ordinary error.
        let vault2 = try makeVault([m.indexPath: m.indexOld])
        var writer2 = try makeWriter(vault2, newJournal())
        writer2.fault = { point in
            switch point {
            case .afterApply(2): try put(vault2, m.paths.record, externalRecord)
            case .beforeApply(3): throw Boom()
            default: break
            }
        }
        let result = try writer2.commit(ops, receipt: try receipt(vault2, paths: m.paths), precondition: { true })
        #expect(receiptOf(result) != nil)
        #expect(text(vault2, m.paths.record) == externalRecord)
        #expect(brokenRelativeLinks(vault2) == [])
    }

    @Test func completionHittingConflictIsPartialWithoutBrokenLinks() throws {
        let m = MeetingFixture()
        let externalRecord = MeetingFixture.edited(m.record(linking: [m.gotchaPath]))
        let vault = try makeVault([m.indexPath: m.indexOld, m.gotchaPath: "A\n"])
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { point in
            switch point {
            case .afterApply(1): try put(vault, m.paths.record, externalRecord)
            case .beforeApply(2):
                try put(vault, m.gotchaPath, "C\n")
                throw Boom()
            default: break
            }
        }
        let item = UUID()
        let result = try writer.commit([
            .create(path: m.paths.transcript, content: m.transcript, itemID: nil),
            .create(path: m.paths.record, content: m.record(linking: [m.gotchaPath]), itemID: nil),
            .update(path: m.gotchaPath, content: m.knowledge(m.gotchaPath, base: "A\n"), expectedHash: h("A\n"), itemID: item),
        ], receipt: try receipt(vault, paths: m.paths), precondition: { true })

        let conflict = OKConflict(itemID: item, path: m.gotchaPath, currentContent: "C\n", currentHash: h("C\n"))
        guard case let .partial(r, conflicts, divergences) = result else {
            Issue.record("esperava .partial, veio \(result)")
            return
        }
        #expect(conflicts == [conflict])
        #expect(divergences == [])
        #expect(r.written == [m.paths.transcript, m.paths.record])
        #expect(text(vault, m.gotchaPath) == "C\n")
        #expect(text(vault, m.paths.record) == externalRecord)
        #expect(text(vault, m.paths.transcript) == m.transcript)
        #expect(brokenRelativeLinks(vault) == [])
        #expect(try OKVaultWriter.recover(journalDirectory: journal) == .partial(r, conflicts: [conflict], divergences: []))
    }

    @Test func ioErrorDuringCompletionKeepsJournalAndRetries() throws {
        let m = MeetingFixture()
        let vault = try makeVault([m.indexPath: m.indexOld])
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { point in
            switch point {
            case .afterApply(2): try put(vault, m.paths.record, MeetingFixture.edited(m.record(linking: [m.adrPath])))
            case .beforeApply(3), .forwardBeforeApply(3): throw Boom()
            default: break
            }
        }
        #expect(throws: OKVaultWriter.WriteError.incomplete([m.adrPath])) {
            try writer.commit(meetingOps(m, metadata: true), receipt: try receipt(vault, paths: m.paths), precondition: { true })
        }
        #expect(try phase(journal) == .rollingForward)

        #expect(receiptOf(try OKVaultWriter.recover(journalDirectory: journal)) != nil)
        #expect(text(vault, m.adrPath) == m.knowledge(m.adrPath))
        #expect(brokenRelativeLinks(vault) == [])
    }

    // MARK: Crashes

    @Test func crashAfterEachApplyRecovers() throws {
        for i in 0..<3 {
            let vault = try makeVault(["b.md": "A\n"])
            let original = snapshot(vault)
            let journal = newJournal()
            var writer = try makeWriter(vault, journal)
            writer.fault = { if $0 == .afterApply(i) { throw OKSimulatedCrash() } }
            #expect(throws: OKSimulatedCrash.self) { try writer.commit(threeOps, receipt: try receipt(vault), precondition: { true }) }

            let outcome = try OKVaultWriter.recover(journalDirectory: journal)
            if i == 2 {
                #expect(receiptOf(outcome)?.written == ["a.md", "b.md", "sub/c.md"])
                #expect(text(vault, "b.md") == "B\n")
                #expect(try OKVaultWriter.recover(journalDirectory: journal) == outcome)
            } else {
                #expect(outcome == .rolledBack(conflicts: [], divergences: []), "crash em afterApply(\(i))")
                #expect(snapshot(vault) == original, "crash em afterApply(\(i))")
                #expect(stagingEntries(vault).isEmpty)
                #expect(try OKVaultWriter.recover(journalDirectory: journal) == .nothing)
            }
        }
    }

    @Test func crashBetweenSwapAndPreimageMoveRecovers() throws {
        let vault = try makeVault(["b.md": "A\n"])
        let original = snapshot(vault)
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { if $0 == .afterSwap(0) { throw OKSimulatedCrash() } }
        #expect(throws: OKSimulatedCrash.self) {
            try writer.commit([
                .update(path: "b.md", content: "B\n", expectedHash: h("A\n"), itemID: nil),
                .create(path: "c.md", content: "NC\n", itemID: nil),
            ], receipt: try receipt(vault), precondition: { true })
        }
        #expect(text(vault, "b.md") == "B\n")
        #expect(staged(vault, "tmp-0") == "A\n")
        #expect(staged(vault, "pre-0") == nil)

        #expect(try OKVaultWriter.recover(journalDirectory: journal) == .rolledBack(conflicts: [], divergences: []))
        #expect(snapshot(vault) == original)
    }

    @Test func crashAfterPrepareLeavesVaultUntouched() throws {
        let vault = try makeVault(["b.md": "A\n"])
        let original = snapshot(vault)
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { if $0 == .afterPrepare { throw OKSimulatedCrash() } }
        #expect(throws: OKSimulatedCrash.self) { try writer.commit(threeOps, receipt: try receipt(vault), precondition: { true }) }
        #expect(snapshot(vault) == original)
        #expect(try phase(journal) == .prepared)

        #expect(try OKVaultWriter.recover(journalDirectory: journal) == .rolledBack(conflicts: [], divergences: []))
        #expect(snapshot(vault) == original)
        #expect(stagingEntries(vault).isEmpty)
        #expect(try phase(journal) == nil)
    }

    @Test func crashDuringRollbackIsIdempotent() throws {
        let vault = try makeVault(["b.md": "A\n"])
        let original = snapshot(vault)
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { if $0 == .afterApply(1) { throw OKSimulatedCrash() } }
        #expect(throws: OKSimulatedCrash.self) { try writer.commit(threeOps, receipt: try receipt(vault), precondition: { true }) }

        #expect(throws: OKSimulatedCrash.self) {
            try OKVaultWriter.recover(journalDirectory: journal, fault: { if $0 == .afterRollback(1) { throw OKSimulatedCrash() } })
        }
        #expect(try phase(journal) == .rollingBack)
        #expect(try OKVaultWriter.recover(journalDirectory: journal) == .rolledBack(conflicts: [], divergences: []))
        #expect(snapshot(vault) == original)
        #expect(try OKVaultWriter.recover(journalDirectory: journal) == .nothing)
    }

    @Test func foreignEditThenCrashAfterSwapOfLastUpdateIsNeverConfirmed() throws {
        let vault = try makeVault(["b.md": "A\n"])
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { point in
            switch point {
            case .beforeApply(1): try put(vault, "b.md", "C\n")
            case .afterSwap(1): throw OKSimulatedCrash()
            default: break
            }
        }
        let item = UUID()
        #expect(throws: OKSimulatedCrash.self) {
            try writer.commit([
                .create(path: "a.md", content: "NA\n", itemID: nil),
                .update(path: "b.md", content: "B\n", expectedHash: h("A\n"), itemID: item),
            ], receipt: try receipt(vault), precondition: { true })
        }
        #expect(text(vault, "b.md") == "B\n")
        #expect(staged(vault, "tmp-1") == "C\n")

        let outcome = try OKVaultWriter.recover(journalDirectory: journal)
        #expect(outcome == .rolledBack(conflicts: [OKConflict(itemID: item, path: "b.md", currentContent: "C\n", currentHash: h("C\n"))], divergences: []))
        #expect(text(vault, "b.md") == "C\n")
        #expect(text(vault, "a.md") == nil)
        #expect(try OKVaultWriter.recover(journalDirectory: journal) == .nothing)
    }

    @Test func crashInsideCreateRollbackAfterCapturingForeignKeepsItAndCompletes() throws {
        // Three creates, so a crash after the second leaves something to roll back.
        let vault = try makeVault()
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { if $0 == .afterApply(1) { throw OKSimulatedCrash() } }
        #expect(throws: OKSimulatedCrash.self) {
            try writer.commit([
                .create(path: "a.md", content: "NA\n", itemID: nil),
                .create(path: "b.md", content: "NB\n", itemID: nil),
                .create(path: "c.md", content: "NC\n", itemID: nil),
            ], receipt: try receipt(vault), precondition: { true })
        }

        #expect(throws: OKSimulatedCrash.self) {
            try OKVaultWriter.recover(journalDirectory: journal, fault: { point in
                switch point {
                case .rollbackBeforeUndo(1): try put(vault, "b.md", "C\n")
                case .rollbackAfterUndo(1): throw OKSimulatedCrash()
                default: break
                }
            })
        }
        #expect(staged(vault, "removed-1") == "C\n")
        #expect(text(vault, "b.md") == nil)

        let outcome = try OKVaultWriter.recover(journalDirectory: journal)
        #expect(receiptOf(outcome)?.written == ["a.md", "b.md", "c.md"])
        #expect(text(vault, "a.md") == "NA\n")
        #expect(text(vault, "b.md") == "C\n")
        #expect(text(vault, "c.md") == "NC\n")
        #expect(try OKVaultWriter.recover(journalDirectory: journal) == outcome)
        #expect(text(vault, "b.md") == "C\n")
    }

    @Test func crashInsideUpdateRollbackAfterCapturingForeignRestoresIt() throws {
        // A create after the update, so the crash after it isn't the last apply.
        let vault = try makeVault(["b.md": "A\n"])
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { if $0 == .afterApply(0) { throw OKSimulatedCrash() } }
        #expect(throws: OKSimulatedCrash.self) {
            try writer.commit([
                .update(path: "b.md", content: "B\n", expectedHash: h("A\n"), itemID: nil),
                .create(path: "c.md", content: "NC\n", itemID: nil),
            ], receipt: try receipt(vault), precondition: { true })
        }

        #expect(throws: OKSimulatedCrash.self) {
            try OKVaultWriter.recover(journalDirectory: journal, fault: { point in
                switch point {
                case .rollbackBeforeUndo(0): try put(vault, "b.md", "C\n")
                case .rollbackAfterUndo(0): throw OKSimulatedCrash()
                default: break
                }
            })
        }
        #expect(text(vault, "b.md") == "A\n")
        #expect(staged(vault, "pre-0") == "C\n")

        let outcome = try OKVaultWriter.recover(journalDirectory: journal)
        #expect(receiptOf(outcome)?.written == ["b.md", "c.md"])
        #expect(text(vault, "b.md") == "C\n")
        #expect(text(vault, "c.md") == "NC\n")
        #expect(staged(vault, "pre-0") == "A\n")
        #expect(try OKVaultWriter.recover(journalDirectory: journal) == outcome)
        #expect(text(vault, "b.md") == "C\n")
    }

    @Test func foreignEditsBeforeAndAfterSwapAreKeptAndComplete() throws {
        let m = MeetingFixture()
        let z = MeetingFixture.edited(m.knowledge(m.adrPath, base: "A\n"))
        let vault = try makeVault([m.indexPath: m.indexOld, m.adrPath: "A\n"])
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { point in
            switch point {
            case .beforeApply(2): try put(vault, m.adrPath, "C\n")
            case .afterSwap(2):
                try put(vault, m.adrPath, z)
                throw OKSimulatedCrash()
            default: break
            }
        }
        let item = UUID()
        #expect(throws: OKSimulatedCrash.self) {
            try writer.commit(updateADROps(m, adrItem: item), receipt: try receipt(vault, paths: m.paths), precondition: { true })
        }
        #expect(throws: OKSimulatedCrash.self) {
            try OKVaultWriter.recover(journalDirectory: journal, fault: { if $0 == .forwardBeforeApply(0) { throw OKSimulatedCrash() } })
        }

        let outcome = try OKVaultWriter.recover(journalDirectory: journal)
        guard case let .partial(r, conflicts, divergences) = outcome else {
            Issue.record("esperava .partial, veio \(outcome)")
            return
        }
        #expect(conflicts == [OKConflict(itemID: item, path: m.adrPath, currentContent: z, currentHash: h(z))])
        #expect(divergences.map(\.path) == [m.adrPath])
        #expect(divergences.first?.preservedCopy.flatMap(contents) == "C\n")
        #expect(r.written == [m.paths.transcript, m.paths.record])
        #expect(text(vault, m.adrPath) == z)
        #expect(text(vault, m.paths.record) == m.record(linking: [m.adrPath]))
        #expect(text(vault, m.paths.transcript) == m.transcript)
        #expect(brokenRelativeLinks(vault) == [])
        #expect(try OKVaultWriter.recover(journalDirectory: journal) == outcome)

        let txid = try #require(try OKVaultWriter.Journal.load(from: journal)?.txid)
        let kept = try OKVaultWriter.finish(journalDirectory: journal)
        #expect(kept.map(\.path) == [m.adrPath])
        let copy = try #require(kept.first?.preservedCopy)
        #expect(copy.contains(".ok/local/voicetype-preserved/\(txid.uuidString)/"))
        #expect(contents(copy) == "C\n")
        #expect(text(vault, m.adrPath) == z)
        #expect(try phase(journal) == nil)
        #expect(stagingEntries(vault).isEmpty)
    }

    @Test func deletedDependencyDuringCompletionIsRestored() throws {
        let m = MeetingFixture()
        for (victimIndex, victim) in [(1, m.paths.record), (0, m.paths.transcript)] {
            let vault = try makeVault([m.indexPath: m.indexOld])
            let journal = newJournal()
            var writer = try makeWriter(vault, journal)
            let externalADR = MeetingFixture.edited(m.knowledge(m.adrPath))
            writer.fault = { point in
                switch point {
                case .afterApply(2): try put(vault, m.adrPath, externalADR)
                case .beforeApply(3):
                    try del(vault, victim)
                    throw OKSimulatedCrash()
                default: break
                }
            }
            let ops = meetingOps(m)
            #expect(throws: OKSimulatedCrash.self) {
                try writer.commit(ops, receipt: try receipt(vault, paths: m.paths), precondition: { true })
            }
            #expect(throws: OKSimulatedCrash.self) {
                try OKVaultWriter.recover(journalDirectory: journal, fault: { if $0 == .forwardBeforeRestore(victimIndex) { throw OKSimulatedCrash() } })
            }
            #expect(try phase(journal) == .rollingForward)
            #expect(text(vault, victim) == nil)

            let outcome = try OKVaultWriter.recover(journalDirectory: journal)
            #expect(receiptOf(outcome) != nil, "vítima \(victim)")
            let approved = victimIndex == 1 ? m.record(linking: [m.adrPath]) : m.transcript
            #expect(text(vault, victim) == approved)
            #expect(text(vault, m.adrPath) == externalADR)
            #expect(text(vault, m.indexPath) == m.indexNew)
            #expect(brokenRelativeLinks(vault) == [])
        }
    }

    @Test func unrestorableDependencyKeepsJournalAndNeverCommits() throws {
        let m = MeetingFixture()
        let vault = try makeVault([m.indexPath: m.indexOld])
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        let failRestore: @Sendable (OKFaultPoint) throws -> Void = { if $0 == .forwardBeforeRestore(1) { throw Boom() } }
        writer.fault = { point in
            switch point {
            case .afterApply(2): try put(vault, m.adrPath, MeetingFixture.edited(m.knowledge(m.adrPath)))
            case .beforeApply(3):
                try del(vault, m.paths.record)
                throw Boom()
            default: try failRestore(point)
            }
        }
        #expect(throws: OKVaultWriter.WriteError.incomplete([m.paths.record])) {
            try writer.commit(meetingOps(m), receipt: try receipt(vault, paths: m.paths), precondition: { true })
        }
        for _ in 0..<2 {
            #expect(throws: OKVaultWriter.WriteError.incomplete([m.paths.record])) {
                try OKVaultWriter.recover(journalDirectory: journal, fault: failRestore)
            }
            #expect(try phase(journal) == .rollingForward)
        }

        #expect(receiptOf(try OKVaultWriter.recover(journalDirectory: journal)) != nil)
        #expect(text(vault, m.paths.record) == m.record(linking: [m.adrPath]))
        #expect(brokenRelativeLinks(vault) == [])
    }

    @Test func restoreNeverOverwritesForeignPreimage() throws {
        let m = MeetingFixture()
        let externalRecord = MeetingFixture.edited(m.record(linking: [m.adrPath]))
        let vault = try makeVault([m.indexPath: m.indexOld, m.adrPath: "A\n"])
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { point in
            switch point {
            case .afterApply(1): try put(vault, m.paths.record, externalRecord)
            case .beforeApply(2): try put(vault, m.adrPath, "C\n")
            case .afterSwap(2):
                try del(vault, m.adrPath)
                throw OKSimulatedCrash()
            default: break
            }
        }
        let item = UUID()
        #expect(throws: OKSimulatedCrash.self) {
            try writer.commit(updateADROps(m, adrItem: item), receipt: try receipt(vault, paths: m.paths), precondition: { true })
        }
        #expect(staged(vault, "tmp-2") == "C\n")
        #expect(text(vault, m.adrPath) == nil)

        #expect(throws: OKSimulatedCrash.self) {
            try OKVaultWriter.recover(journalDirectory: journal, fault: { if $0 == .forwardBeforeRestore(2) { throw OKSimulatedCrash() } })
        }
        #expect(staged(vault, "tmp-2") == "C\n" || staged(vault, "pre-2") == "C\n")

        let outcome = try OKVaultWriter.recover(journalDirectory: journal)
        guard case let .partial(_, conflicts, divergences) = outcome else {
            Issue.record("esperava .partial, veio \(outcome)")
            return
        }
        #expect(conflicts == [OKConflict(itemID: item, path: m.adrPath, currentContent: "C\n", currentHash: h("C\n"))])
        #expect(divergences == [])
        #expect(text(vault, m.adrPath) == "C\n")
        #expect(text(vault, m.paths.record) == externalRecord)
        #expect(text(vault, m.paths.transcript) == m.transcript)
        #expect(brokenRelativeLinks(vault) == [])
        #expect(try OKVaultWriter.recover(journalDirectory: journal) == outcome)
        #expect(text(vault, m.adrPath) == "C\n")
    }

    @Test func foreignRewriteAfterUpdateUndoForcesCompletion() throws {
        let m = MeetingFixture()
        let n = m.knowledge(m.adrPath, base: "A\n")
        let z = MeetingFixture.edited(n)
        let ops = updateADROps(m) + [.create(path: "p5/c.md", content: "NC\n", itemID: nil)]

        /// Commits with a crash after the ADR swap, then a first recover
        /// whose `fault` runs during the rollback.
        func crashThenRecover(_ fault: @escaping @Sendable (URL, OKFaultPoint) throws -> Void) throws -> (URL, URL) {
            let vault = try makeVault([m.indexPath: m.indexOld, m.adrPath: "A\n"])
            let journal = newJournal()
            var writer = try makeWriter(vault, journal)
            writer.fault = { if $0 == .afterApply(2) { throw OKSimulatedCrash() } }
            #expect(throws: OKSimulatedCrash.self) {
                try writer.commit(ops, receipt: try receipt(vault, paths: m.paths), precondition: { true })
            }
            #expect(throws: OKSimulatedCrash.self) {
                try OKVaultWriter.recover(journalDirectory: journal, fault: { try fault(vault, $0) })
            }
            return (vault, journal)
        }

        func expectCompleted(_ vault: URL, _ journal: URL, adr: String) throws {
            let outcome = try OKVaultWriter.recover(journalDirectory: journal)
            #expect(receiptOf(outcome)?.written == ops.map(\.path))
            #expect(text(vault, m.adrPath) == adr)
            #expect(text(vault, m.paths.record) == m.record(linking: [m.adrPath]))
            #expect(text(vault, m.paths.transcript) == m.transcript)
            #expect(text(vault, "p5/c.md") == "NC\n")
            #expect(brokenRelativeLinks(vault) == [])
            let settled = snapshot(vault)
            #expect(try OKVaultWriter.recover(journalDirectory: journal) == outcome)
            #expect(try OKVaultWriter.recover(journalDirectory: journal) == outcome)
            #expect(snapshot(vault) == settled)
        }

        // Z written over E right after the ADR was undone.
        var (vault, journal) = try crashThenRecover { vault, point in
            if point == .afterRollback(2) {
                try put(vault, m.adrPath, z)
                throw OKSimulatedCrash()
            }
        }
        #expect(staged(vault, "pre-2") == n)
        try expectCompleted(vault, journal, adr: z)

        // Same, but the record had already been taken out (removed-1).
        (vault, journal) = try crashThenRecover { vault, point in
            if point == .afterRollback(1) {
                try put(vault, m.adrPath, z)
                throw OKSimulatedCrash()
            }
        }
        #expect(text(vault, m.paths.record) == nil)
        try expectCompleted(vault, journal, adr: z)

        // Z without a crash: the next step's reclassification completes on the spot.
        let vault2 = try makeVault([m.indexPath: m.indexOld, m.adrPath: "A\n"])
        let journal2 = newJournal()
        var writer = try makeWriter(vault2, journal2)
        writer.fault = { if $0 == .afterApply(2) { throw OKSimulatedCrash() } }
        #expect(throws: OKSimulatedCrash.self) {
            try writer.commit(ops, receipt: try receipt(vault2, paths: m.paths), precondition: { true })
        }
        let direct = try OKVaultWriter.recover(journalDirectory: journal2, fault: { point in
            if point == .afterRollback(2) { try put(vault2, m.adrPath, z) }
            if point == .afterRollback(1) { throw OKSimulatedCrash() }
        })
        #expect(receiptOf(direct) != nil)
        #expect(text(vault2, m.adrPath) == z)
        #expect(brokenRelativeLinks(vault2) == [])

        // Exact replay of N's bytes after the undo: replayedAfterUndo, never a repair.
        (vault, journal) = try crashThenRecover { vault, point in
            if point == .afterRollback(2) {
                try put(vault, m.adrPath, n)
                throw OKSimulatedCrash()
            }
        }
        try expectCompleted(vault, journal, adr: n)
        let adrOp = try #require(try OKVaultWriter.Journal.load(from: journal)?.ops.first { $0.path == m.adrPath })
        #expect(adrOp.foreignPreimageHash == nil)

        (vault, journal) = try crashThenRecover { vault, point in
            if point == .afterRollback(1) {
                try put(vault, m.adrPath, n)
                throw OKSimulatedCrash()
            }
        }
        #expect(text(vault, m.paths.record) == nil)
        try expectCompleted(vault, journal, adr: n)
    }

    @Test func restoreAfterDeletedAfterUndoIsInPlace() throws {
        let m = MeetingFixture()
        let n = m.knowledge(m.adrPath, base: "A\n")
        let externalRecord = MeetingFixture.edited(m.record(linking: [m.adrPath]))
        let ops = updateADROps(m) + [.create(path: "p5/c.md", content: "NC\n", itemID: nil)]
        let vault = try makeVault([m.indexPath: m.indexOld, m.adrPath: "A\n"])
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { if $0 == .afterApply(2) { throw OKSimulatedCrash() } }
        #expect(throws: OKSimulatedCrash.self) {
            try writer.commit(ops, receipt: try receipt(vault, paths: m.paths), precondition: { true })
        }
        #expect(throws: OKSimulatedCrash.self) {
            try OKVaultWriter.recover(journalDirectory: journal, fault: { point in
                if point == .afterRollback(2) {
                    try put(vault, m.paths.record, externalRecord)
                    try del(vault, m.adrPath)
                    throw OKSimulatedCrash()
                }
            })
        }
        #expect(staged(vault, "pre-2") == n)
        #expect(text(vault, m.adrPath) == nil)

        #expect(throws: OKSimulatedCrash.self) {
            try OKVaultWriter.recover(journalDirectory: journal, fault: { if $0 == .forwardBeforeApply(3) { throw OKSimulatedCrash() } })
        }
        #expect(try phase(journal) == .rollingForward)
        #expect(text(vault, m.adrPath) == n)
        #expect(staged(vault, "pre-2") == n)

        let outcome = try OKVaultWriter.recover(journalDirectory: journal)
        #expect(receiptOf(outcome)?.written == ops.map(\.path))
        #expect(text(vault, m.adrPath) == n)
        #expect(text(vault, m.paths.record) == externalRecord)
        #expect(text(vault, "p5/c.md") == "NC\n")
        #expect(brokenRelativeLinks(vault) == [])
    }

    // MARK: Dependencies

    @Test func dependenciesOutsideOpsAreRestoredBeforeCommit() throws {
        let m = MeetingFixture()
        let record = m.record(linking: [m.adrPath, m.adr2Path])
        let files = [
            m.indexPath: m.indexOld, m.paths.record: record, m.paths.transcript: m.transcript,
            m.adrPath: "A1\n", m.adr2Path: "A2\n",
        ]
        let deps = [m.paths.record, m.paths.transcript]
        let n1 = m.knowledge(m.adrPath, base: "A1\n")
        let n2 = m.knowledge(m.adr2Path, base: "A2\n")
        let ops: [OKVaultOp] = [
            .update(path: m.adrPath, content: n1, expectedHash: h("A1\n"), itemID: nil),
            .update(path: m.adr2Path, content: n2, expectedHash: h("A2\n"), itemID: nil),
        ]

        // Completion (ADR1 edited after ours) restores the record from dep-0.
        var vault = try makeVault(files)
        var journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { [vault] point in
            switch point {
            case .afterApply(0): try put(vault, m.adrPath, MeetingFixture.edited(n1))
            case .beforeApply(1):
                try del(vault, m.paths.record)
                throw Boom()
            default: break
            }
        }
        var result = try writer.commit(ops, dependencies: deps, receipt: try receipt(vault, paths: m.paths), precondition: { true })
        #expect(receiptOf(result)?.written == [m.adrPath, m.adr2Path])
        #expect(text(vault, m.paths.record) == record)
        #expect(text(vault, m.adr2Path) == n2)
        #expect(brokenRelativeLinks(vault) == [])

        // Normal path: the final check restores a dependency deleted after the last apply.
        vault = try makeVault(files)
        writer = try makeWriter(vault, newJournal())
        writer.fault = { [vault] point in
            if point == .afterApply(0) { try del(vault, m.paths.transcript) }
        }
        result = try writer.commit([ops[0]], dependencies: deps, receipt: try receipt(vault, paths: m.paths), precondition: { true })
        #expect(receiptOf(result) != nil)
        #expect(text(vault, m.paths.transcript) == m.transcript)
        #expect(brokenRelativeLinks(vault) == [])

        // A dependency that can't be restored never commits.
        vault = try makeVault(files)
        journal = newJournal()
        writer = try makeWriter(vault, journal)
        let failRestore: @Sendable (OKFaultPoint) throws -> Void = { if $0 == .forwardBeforeRestoreDependency(0) { throw Boom() } }
        writer.fault = { [vault] point in
            switch point {
            case .afterApply(0): try put(vault, m.adrPath, MeetingFixture.edited(n1))
            case .beforeApply(1):
                try del(vault, m.paths.record)
                throw Boom()
            default: try failRestore(point)
            }
        }
        #expect(throws: OKVaultWriter.WriteError.incomplete([m.paths.record])) {
            try writer.commit(ops, dependencies: deps, receipt: try receipt(vault, paths: m.paths), precondition: { true })
        }
        for _ in 0..<2 {
            #expect(throws: OKVaultWriter.WriteError.incomplete([m.paths.record])) {
                try OKVaultWriter.recover(journalDirectory: journal, fault: failRestore)
            }
            #expect(try phase(journal) == .rollingForward)
        }

        // Missing already at validation: conflict, nothing written.
        var missing = files
        missing[m.paths.record] = nil
        vault = try makeVault(missing)
        let original = snapshot(vault)
        journal = newJournal()
        result = try makeWriter(vault, journal).commit(ops, dependencies: deps, receipt: try receipt(vault, paths: m.paths), precondition: { true })
        #expect(result == .conflicts([OKConflict(itemID: nil, path: m.paths.record, currentContent: nil, currentHash: nil)], divergences: []))
        #expect(snapshot(vault) == original)
        #expect(!FileManager.default.fileExists(atPath: stagingRoot(vault).path))
        #expect(try phase(journal) == nil)

        // A no-op update is dropped and becomes a dependency.
        vault = try makeVault(files)
        journal = newJournal()
        result = try makeWriter(vault, journal).commit([
            .update(path: m.adr2Path, content: "A2\n", expectedHash: h("A2\n"), itemID: nil),
            ops[0],
        ], dependencies: deps, receipt: try receipt(vault, paths: m.paths), precondition: { true })
        #expect(receiptOf(result)?.written == [m.adrPath])
        let saved = try #require(try OKVaultWriter.Journal.load(from: journal))
        #expect(saved.ops.map(\.path) == [m.adrPath])
        #expect(saved.dependencies.map(\.path) == [m.paths.record, m.paths.transcript, m.adr2Path])
    }

    // MARK: Interrupted cleanup and late changes

    /// update b.md ("A\n" → "B\n"), create c.md.
    private let updateThenCreate: [OKVaultOp] = [
        .update(path: "b.md", content: "B\n", expectedHash: h("A\n"), itemID: nil),
        .create(path: "c.md", content: "NC\n", itemID: nil),
    ]

    @Test func crashDuringRollbackCleanupOnlyResumesCleanup() throws {
        // The rollback undid the update (pre-0 == N); each staging file deleted
        // before the crash is evidence the next recover must not need.
        for name in ["pre-0", "copy-0", "tmp-1", "copy-1"] {
            let vault = try makeVault(["b.md": "A\n"])
            let original = snapshot(vault)
            let journal = newJournal()
            var writer = try makeWriter(vault, journal)
            writer.fault = { if $0 == .afterApply(0) { throw OKSimulatedCrash() } }
            #expect(throws: OKSimulatedCrash.self) { try writer.commit(updateThenCreate, receipt: try receipt(vault), precondition: { true }) }

            #expect(throws: OKSimulatedCrash.self) {
                try OKVaultWriter.recover(journalDirectory: journal, fault: { if $0 == .cleanupBeforeDelete(name) { throw OKSimulatedCrash() } })
            }
            #expect(try phase(journal) == .rolledBack, "crash antes de apagar \(name)")
            #expect(snapshot(vault) == original, "crash antes de apagar \(name)")

            #expect(try OKVaultWriter.recover(journalDirectory: journal) == .rolledBack(conflicts: [], divergences: []), "crash antes de apagar \(name)")
            #expect(snapshot(vault) == original, "crash antes de apagar \(name)")
            #expect(stagingEntries(vault).isEmpty)
            #expect(try phase(journal) == nil)
            #expect(try OKVaultWriter.recover(journalDirectory: journal) == .nothing)
        }
    }

    @Test func artifactChangedAfterInterruptedCleanupIsPreserved() throws {
        let vault = try makeVault(["b.md": "A\n"])
        let original = snapshot(vault)
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { if $0 == .afterApply(0) { throw OKSimulatedCrash() } }
        #expect(throws: OKSimulatedCrash.self) { try writer.commit(updateThenCreate, receipt: try receipt(vault), precondition: { true }) }

        // An editor opened b.md while our N was in place and keeps the descriptor;
        // the rollback moves that inode to pre-0.
        let editor = try FileHandle(forUpdating: vault.appendingPathComponent("b.md"))
        defer { try? editor.close() }
        #expect(throws: OKSimulatedCrash.self) {
            try OKVaultWriter.recover(journalDirectory: journal, fault: { if $0 == .cleanupBeforeDelete("pre-0") { throw OKSimulatedCrash() } })
        }
        #expect(try phase(journal) == .rolledBack)
        #expect(try OKVaultWriter.Journal.load(from: journal)?.divergences == nil)
        try editor.truncate(atOffset: 0)
        try editor.write(contentsOf: Data("X\n".utf8))
        try editor.synchronize()
        #expect(staged(vault, "pre-0") == "X\n")
        #expect(text(vault, "b.md") == "A\n")

        let outcome = try OKVaultWriter.recover(journalDirectory: journal)
        guard case let .rolledBack(conflicts, divergences) = outcome else {
            Issue.record("esperava .rolledBack, veio \(outcome)")
            return
        }
        #expect(conflicts == [])
        #expect(divergences.map(\.path) == ["b.md"])
        #expect(divergences.first?.preservedCopy.flatMap(contents) == "X\n")
        #expect(try phase(journal) == .rolledBackWithDivergences)
        #expect(snapshot(vault) == original)
        #expect(staged(vault, "copy-0") == nil)

        #expect(try OKVaultWriter.recover(journalDirectory: journal) == .rolledBack(conflicts: [], divergences: divergences))
        #expect(try OKVaultWriter.recover(journalDirectory: journal) == .rolledBack(conflicts: [], divergences: divergences))
        #expect(divergences.first?.preservedCopy.flatMap(contents) == "X\n")
        #expect(snapshot(vault) == original)
    }

    @Test func artifactWrittenDuringRollbackCleanupIsPreserved() throws {
        // As above, but the editor writes after the cleanup read pre-0 as our N.
        let vault = try makeVault(["b.md": "A\n"])
        let original = snapshot(vault)
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { if $0 == .afterApply(0) { throw OKSimulatedCrash() } }
        #expect(throws: OKSimulatedCrash.self) { try writer.commit(updateThenCreate, receipt: try receipt(vault), precondition: { true }) }
        let txid = try #require(try OKVaultWriter.Journal.load(from: journal)?.txid)

        let editor = try FileHandle(forUpdating: vault.appendingPathComponent("b.md"))
        defer { try? editor.close() }
        let outcome = try OKVaultWriter.recover(journalDirectory: journal, fault: { point in
            if point == .cleanupBeforeDelete("pre-0") {
                try editor.truncate(atOffset: 0)
                try editor.write(contentsOf: Data("X\n".utf8))
                try editor.synchronize()
            }
        })
        guard case let .rolledBack(conflicts, divergences) = outcome else {
            Issue.record("esperava .rolledBack, veio \(outcome)")
            return
        }
        #expect(conflicts == [])
        #expect(divergences.map(\.path) == ["b.md"])
        let copy = try #require(divergences.first?.preservedCopy)
        #expect(copy.hasSuffix(".ok/local/voicetype-preserved/\(txid.uuidString)/pre-0"))
        #expect(contents(copy) == "X\n")
        #expect(try phase(journal) == .rolledBackWithDivergences)
        #expect(try OKVaultWriter.recover(journalDirectory: journal) == .rolledBack(conflicts: [], divergences: divergences))
        #expect(snapshot(vault) == original)
    }

    @Test func unchangedArtifactIsRetainedByRollbackCleanup() throws {
        // Control: nothing written during the cleanup. pre-0 still leaves the
        // staging by a rename, so a later write through the descriptor survives.
        let vault = try makeVault(["b.md": "A\n"])
        let original = snapshot(vault)
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { if $0 == .afterApply(0) { throw OKSimulatedCrash() } }
        #expect(throws: OKSimulatedCrash.self) { try writer.commit(updateThenCreate, receipt: try receipt(vault), precondition: { true }) }
        let txid = try #require(try OKVaultWriter.Journal.load(from: journal)?.txid)

        let editor = try FileHandle(forUpdating: vault.appendingPathComponent("b.md"))
        defer { try? editor.close() }
        #expect(try OKVaultWriter.recover(journalDirectory: journal) == .rolledBack(conflicts: [], divergences: []))
        #expect(try phase(journal) == nil)
        #expect(stagingEntries(vault).isEmpty)
        #expect(snapshot(vault) == original)
        let preserved = vault.appendingPathComponent(".ok/local/voicetype-preserved/\(txid.uuidString)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: preserved.path) == ["pre-0"])
        #expect(contents(preserved.appendingPathComponent("pre-0").path) == "B\n")

        try editor.truncate(atOffset: 0)
        try editor.write(contentsOf: Data("Y\n".utf8))
        try editor.synchronize()
        #expect(contents(preserved.appendingPathComponent("pre-0").path) == "Y\n")
        #expect(text(vault, "b.md") == "A\n")
    }

    @Test func rollbackConflictsSurviveInterruptedCleanup() throws {
        let vault = try makeVault(["b.md": "A\n"])
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { point in
            switch point {
            case .beforeApply(1): try put(vault, "b.md", "C\n")
            case .afterSwap(1): throw OKSimulatedCrash()
            default: break
            }
        }
        let item = UUID()
        #expect(throws: OKSimulatedCrash.self) {
            try writer.commit([
                .create(path: "a.md", content: "NA\n", itemID: nil),
                .update(path: "b.md", content: "B\n", expectedHash: h("A\n"), itemID: item),
            ], receipt: try receipt(vault), precondition: { true })
        }
        // removed-0 is already gone when the crash hits copy-0.
        #expect(throws: OKSimulatedCrash.self) {
            try OKVaultWriter.recover(journalDirectory: journal, fault: { if $0 == .cleanupBeforeDelete("copy-0") { throw OKSimulatedCrash() } })
        }
        #expect(try phase(journal) == .rolledBack)

        let conflict = OKConflict(itemID: item, path: "b.md", currentContent: "C\n", currentHash: h("C\n"))
        #expect(try OKVaultWriter.recover(journalDirectory: journal) == .rolledBack(conflicts: [conflict], divergences: []))
        #expect(text(vault, "b.md") == "C\n")
        #expect(text(vault, "a.md") == nil)
        #expect(try OKVaultWriter.recover(journalDirectory: journal) == .nothing)
    }

    @Test func ioErrorDuringRollbackCleanupKeepsJournalForRecover() throws {
        let vault = try makeVault(["b.md": "A\n"])
        let original = snapshot(vault)
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { if $0 == .afterApply(0) { throw OKSimulatedCrash() } }
        #expect(throws: OKSimulatedCrash.self) { try writer.commit(updateThenCreate, receipt: try receipt(vault), precondition: { true }) }

        #expect(throws: Boom.self) {
            try OKVaultWriter.recover(journalDirectory: journal, fault: { if $0 == .cleanupBeforeDelete("copy-0") { throw Boom() } })
        }
        #expect(try phase(journal) == .rolledBack)
        #expect(try OKVaultWriter.recover(journalDirectory: journal) == .rolledBack(conflicts: [], divergences: []))
        #expect(snapshot(vault) == original)
        #expect(stagingEntries(vault).isEmpty)
        #expect(try phase(journal) == nil)
    }

    @Test func interruptedCancellationNeverAppliesAnything() throws {
        for name in ["tmp-0", "copy-0", "tmp-1", "copy-1"] {
            let vault = try makeVault(["b.md": "A\n"])
            let original = snapshot(vault)
            let journal = newJournal()
            var writer = try makeWriter(vault, journal)
            writer.fault = { if $0 == .cleanupBeforeDelete(name) { throw OKSimulatedCrash() } }
            #expect(throws: OKSimulatedCrash.self) { try writer.commit(updateThenCreate, receipt: try receipt(vault), precondition: { false }) }
            #expect(try phase(journal) == .rolledBack, "crash antes de apagar \(name)")

            #expect(try OKVaultWriter.recover(journalDirectory: journal) == .rolledBack(conflicts: [], divergences: []), "crash antes de apagar \(name)")
            #expect(snapshot(vault) == original, "crash antes de apagar \(name)")
            #expect(stagingEntries(vault).isEmpty)
            #expect(try phase(journal) == nil)
        }

        // An ordinary error in the cleanup: still preconditionFailed, the journal finishes it later.
        let vault = try makeVault(["b.md": "A\n"])
        let original = snapshot(vault)
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { if $0 == .cleanupBeforeDelete("copy-0") { throw Boom() } }
        #expect(try writer.commit(updateThenCreate, receipt: try receipt(vault), precondition: { false }) == .preconditionFailed)
        #expect(try phase(journal) == .rolledBack)
        #expect(try OKVaultWriter.recover(journalDirectory: journal) == .rolledBack(conflicts: [], divergences: []))
        #expect(snapshot(vault) == original)
        #expect(stagingEntries(vault).isEmpty)
    }

    @Test func earlierOpChangedDuringLaterForwardStepIsReconciled() throws {
        // As restoreAfterDeletedAfterUndoIsInPlace; then, while the completion is
        // on the last op, E comes back to the ADR and the transcript is deleted.
        let m = MeetingFixture()
        let n = m.knowledge(m.adrPath, base: "A\n")
        let externalRecord = MeetingFixture.edited(m.record(linking: [m.adrPath]))
        let ops = updateADROps(m) + [.create(path: "p5/c.md", content: "NC\n", itemID: nil)]
        let vault = try makeVault([m.indexPath: m.indexOld, m.adrPath: "A\n"])
        let journal = newJournal()
        var writer = try makeWriter(vault, journal)
        writer.fault = { if $0 == .afterApply(2) { throw OKSimulatedCrash() } }
        #expect(throws: OKSimulatedCrash.self) {
            try writer.commit(ops, receipt: try receipt(vault, paths: m.paths), precondition: { true })
        }
        #expect(throws: OKSimulatedCrash.self) {
            try OKVaultWriter.recover(journalDirectory: journal, fault: { point in
                if point == .afterRollback(2) {
                    try put(vault, m.paths.record, externalRecord)
                    try del(vault, m.adrPath)
                    throw OKSimulatedCrash()
                }
            })
        }

        let outcome = try OKVaultWriter.recover(journalDirectory: journal, fault: { point in
            if point == .forwardBeforeApply(3) {
                try put(vault, m.adrPath, "A\n")
                try del(vault, m.paths.transcript)
            }
        })
        #expect(receiptOf(outcome)?.written == ops.map(\.path))
        #expect(text(vault, m.adrPath) == n)
        #expect(staged(vault, "pre-2") == "A\n")
        #expect(text(vault, m.paths.transcript) == m.transcript)
        #expect(text(vault, m.paths.record) == externalRecord)
        #expect(text(vault, "p5/c.md") == "NC\n")
        #expect(brokenRelativeLinks(vault) == [])
    }

    @Test func earlierOpDeletedDuringDependencyRestoreIsRestored() throws {
        let m = MeetingFixture()
        let record = m.record(linking: [m.adrPath, m.adr2Path])
        let files = [
            m.indexPath: m.indexOld, m.paths.record: record, m.paths.transcript: m.transcript,
            m.adrPath: "A1\n", m.adr2Path: "A2\n",
        ]
        let deps = [m.paths.record, m.paths.transcript]
        let n1 = m.knowledge(m.adrPath, base: "A1\n")
        let n2 = m.knowledge(m.adr2Path, base: "A2\n")
        let ops: [OKVaultOp] = [
            .update(path: m.adrPath, content: n1, expectedHash: h("A1\n"), itemID: nil),
            .update(path: m.adr2Path, content: n2, expectedHash: h("A2\n"), itemID: nil),
        ]
        /// ADR1 edited after ours (completion), the record deleted, and ADR2
        /// (already verified) deleted while the record is being restored.
        func hooks(_ vault: URL, failADR2Restore: Bool) -> @Sendable (OKFaultPoint) throws -> Void {
            { point in
                switch point {
                case .afterApply(0): try put(vault, m.adrPath, MeetingFixture.edited(n1))
                case .beforeApply(1):
                    try del(vault, m.paths.record)
                    throw Boom()
                case .forwardBeforeRestoreDependency(0): try? del(vault, m.adr2Path)
                case .forwardBeforeRestore(1): if failADR2Restore { throw Boom() }
                default: break
                }
            }
        }

        var vault = try makeVault(files)
        var writer = try makeWriter(vault, newJournal())
        writer.fault = hooks(vault, failADR2Restore: false)
        let result = try writer.commit(ops, dependencies: deps, receipt: try receipt(vault, paths: m.paths), precondition: { true })
        #expect(receiptOf(result)?.written == [m.adrPath, m.adr2Path])
        #expect(text(vault, m.adr2Path) == n2)
        #expect(text(vault, m.paths.record) == record)
        #expect(brokenRelativeLinks(vault) == [])

        // ADR2 can't be put back: never a receipt that lists it.
        vault = try makeVault(files)
        let journal = newJournal()
        writer = try makeWriter(vault, journal)
        writer.fault = hooks(vault, failADR2Restore: true)
        #expect(throws: OKVaultWriter.WriteError.incomplete([m.adr2Path])) {
            try writer.commit(ops, dependencies: deps, receipt: try receipt(vault, paths: m.paths), precondition: { true })
        }
        #expect(try phase(journal) == .rollingForward)
        #expect(receiptOf(try OKVaultWriter.recover(journalDirectory: journal))?.written == [m.adrPath, m.adr2Path])
        #expect(text(vault, m.adr2Path) == n2)
        #expect(brokenRelativeLinks(vault) == [])
    }

    // MARK: Finish and vault binding

    @Test func finishKeepsForeignArtifacts() throws {
        let vault = try makeVault(["b.md": "A\n"])
        let journal = newJournal()
        let result = try makeWriter(vault, journal).commit(
            [.update(path: "b.md", content: "B\n", expectedHash: h("A\n"), itemID: nil)],
            receipt: try receipt(vault), precondition: { true }
        )
        #expect(receiptOf(result) != nil)
        let txid = try #require(try OKVaultWriter.Journal.load(from: journal)?.txid)
        let staging = stagingRoot(vault).appendingPathComponent(txid.uuidString)
        try Data("X\n".utf8).write(to: staging.appendingPathComponent("pre-0"))

        let kept = try OKVaultWriter.finish(journalDirectory: journal)
        #expect(kept.map(\.path) == ["b.md"])
        let copy = try #require(kept.first?.preservedCopy)
        #expect(copy.hasSuffix(".ok/local/voicetype-preserved/\(txid.uuidString)/pre-0"))
        #expect(contents(copy) == "X\n")
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(try phase(journal) == nil)
        #expect(text(vault, "b.md") == "B\n")
        #expect(try OKVaultWriter.finish(journalDirectory: journal) == [])
    }

    @Test func finishRetriedAfterAFailureStillReportsTheOutsideVersion() throws {
        // b.md's pre-image holds an outside version; the first attempt moves
        // it and fails on c.md's, so only the retry gets to return.
        let vault = try makeVault(["b.md": "A\n", "c.md": "C\n"])
        let journal = newJournal()
        let result = try makeWriter(vault, journal).commit(
            [.update(path: "b.md", content: "B\n", expectedHash: h("A\n"), itemID: nil),
             .update(path: "c.md", content: "D\n", expectedHash: h("C\n"), itemID: nil)],
            receipt: try receipt(vault), precondition: { true }
        )
        #expect(receiptOf(result) != nil)
        let txid = try #require(try OKVaultWriter.Journal.load(from: journal)?.txid)
        let staging = stagingRoot(vault).appendingPathComponent(txid.uuidString)
        try Data("X\n".utf8).write(to: staging.appendingPathComponent("pre-0"))
        let preserved = vault.appendingPathComponent(".ok/local/voicetype-preserved/\(txid.uuidString)")

        #expect(throws: OKSimulatedCrash.self) {
            try OKVaultWriter.finish(journalDirectory: journal, fault: { if $0 == .cleanupBeforeDelete("pre-1") { throw OKSimulatedCrash() } })
        }
        #expect(contents(preserved.appendingPathComponent("pre-0").path) == "X\n")
        #expect(try phase(journal) == .committed)

        let kept = try OKVaultWriter.finish(journalDirectory: journal)
        #expect(kept == [OKDivergence(path: "b.md", preservedCopy: preserved.appendingPathComponent("pre-0").path,
                                      reason: OKVaultTransaction.foreignReason)])
        #expect(contents(preserved.appendingPathComponent("pre-1").path) == "C\n")
        #expect(stagingEntries(vault).isEmpty)
        #expect(try phase(journal) == nil)
    }

    @Test func finishPreservesArtifactWrittenDuringCleanup() throws {
        // An editor opened b.md before the commit; the swap moves that inode (E) to pre-0.
        for writes in [true, false] {
            let vault = try makeVault(["b.md": "A\n"])
            let journal = newJournal()
            let editor = try FileHandle(forUpdating: vault.appendingPathComponent("b.md"))
            defer { try? editor.close() }
            let result = try makeWriter(vault, journal).commit(
                [.update(path: "b.md", content: "B\n", expectedHash: h("A\n"), itemID: nil)],
                receipt: try receipt(vault), precondition: { true }
            )
            #expect(receiptOf(result) != nil)
            let txid = try #require(try OKVaultWriter.Journal.load(from: journal)?.txid)
            let preserved = vault.appendingPathComponent(".ok/local/voicetype-preserved/\(txid.uuidString)")

            let kept = try OKVaultWriter.finish(journalDirectory: journal, fault: { point in
                if writes, point == .cleanupBeforeDelete("pre-0") {
                    try editor.truncate(atOffset: 0)
                    try editor.write(contentsOf: Data("X\n".utf8))
                    try editor.synchronize()
                }
            })
            if writes {
                #expect(kept.map(\.path) == ["b.md"])
                #expect(kept.first?.preservedCopy == preserved.appendingPathComponent("pre-0").path)
                #expect(contents(preserved.appendingPathComponent("pre-0").path) == "X\n")
            } else {
                #expect(kept == [])
                #expect(contents(preserved.appendingPathComponent("pre-0").path) == "A\n")
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: preserved.path) == ["pre-0"])
            #expect(stagingEntries(vault).isEmpty)
            #expect(try phase(journal) == nil)
            #expect(text(vault, "b.md") == "B\n")
        }
    }

    enum Holder: CaseIterable { case nobody, reader, writer, movedWriter, mapping }

    @Test(arguments: Holder.allCases)
    func finishKeepsThePreimageWhoeverHoldsIt(_ holder: Holder) throws {
        // The swap moves b.md's inode (E) to pre-0. Whether anyone can still
        // write it isn't decided by looking at other processes: it's kept in
        // every case, even when the writer's descriptor moves to another
        // number during the cleanup, and a later write lands in the copy.
        let vault = try makeVault(["b.md": "A\n"])
        let b = vault.appendingPathComponent("b.md")
        let fd = holder == .nobody || holder == .mapping ? -1 : open(b.path, holder == .reader ? O_RDONLY : O_RDWR)
        let held = Descriptor(fd)
        defer { held.close() }
        var mapped: UnsafeMutableRawPointer?
        if holder == .mapping {
            let mfd = open(b.path, O_RDWR)
            try #require(mfd >= 0)
            let p = mmap(nil, 2, PROT_READ | PROT_WRITE, MAP_SHARED, mfd, 0)
            close(mfd)
            try #require(p != MAP_FAILED)
            mapped = p
        }
        defer { if let mapped { munmap(mapped, 2) } }
        let journal = newJournal()
        let result = try makeWriter(vault, journal).commit(
            [.update(path: "b.md", content: "B\n", expectedHash: h("A\n"), itemID: nil)],
            receipt: try receipt(vault), precondition: { true }
        )
        #expect(receiptOf(result) != nil)
        let txid = try #require(try OKVaultWriter.Journal.load(from: journal)?.txid)

        #expect(try OKVaultWriter.finish(journalDirectory: journal, fault: { point in
            if holder == .movedWriter, point == .cleanupBeforeDelete("pre-0") { held.move() }
        }) == [])
        let copy = vault.appendingPathComponent(".ok/local/voicetype-preserved/\(txid.uuidString)/pre-0")
        #expect(contents(copy.path) == "A\n")
        #expect(stagingEntries(vault).isEmpty)
        #expect(try phase(journal) == nil)
        #expect(text(vault, "b.md") == "B\n")

        switch holder {
        case .writer, .movedWriter:
            #expect(pwrite(held.fd, "Z", 1, 0) == 1)
            fsync(held.fd)
            #expect(contents(copy.path) == "Z\n")
        case .mapping:
            mapped?.storeBytes(of: UInt8(ascii: "Z"), as: UInt8.self)
            if let mapped { msync(mapped, 2, MS_SYNC) }
            #expect(contents(copy.path) == "Z\n")
        case .nobody, .reader:
            break
        }
    }

    @Test func recoverUsesJournalVaultNotCurrentConfig() throws {
        let vaultA = try makeVault(["b.md": "A\n"])
        let vaultB = try makeVault(["b.md": "A\n"])
        let originalA = snapshot(vaultA)
        let originalB = snapshot(vaultB)
        var journal = newJournal()
        var writer = try makeWriter(vaultA, journal)
        writer.fault = { if $0 == .afterApply(1) { throw OKSimulatedCrash() } }
        #expect(throws: OKSimulatedCrash.self) { try writer.commit(threeOps, receipt: try receipt(vaultA), precondition: { true }) }

        #expect(try OKVaultWriter.recover(journalDirectory: journal) == .rolledBack(conflicts: [], divergences: []))
        #expect(snapshot(vaultA) == originalA)
        #expect(snapshot(vaultB) == originalB)

        // The same folder deleted and recreated is another vault.
        let identityA = try OKVaultIdentity.of(vaultA)
        journal = newJournal()
        writer = try makeWriter(vaultA, journal)
        writer.fault = { if $0 == .afterApply(1) { throw OKSimulatedCrash() } }
        #expect(throws: OKSimulatedCrash.self) { try writer.commit(threeOps, receipt: try receipt(vaultA), precondition: { true }) }
        try FileManager.default.removeItem(at: vaultA)
        try FileManager.default.createDirectory(at: vaultA.appendingPathComponent(".ok", isDirectory: true), withIntermediateDirectories: true)

        #expect(try OKVaultWriter.recover(journalDirectory: journal) == .vaultUnavailable(root: identityA.root))
        #expect(try FileManager.default.contentsOfDirectory(atPath: vaultA.path) == [".ok"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: vaultA.appendingPathComponent(".ok").path) == [])
        #expect(try phase(journal) == .prepared)
    }
}
