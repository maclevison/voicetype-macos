import Foundation
import Testing
@testable import Core

@Suite("OKInbox")
struct OKInboxTests {
    private let utc = TimeZone(identifier: "UTC")!
    // 2026-10-14 14:32:00 UTC
    private let date = Date(timeIntervalSince1970: 1_791_988_320)
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000079")!

    private func makeVault() throws -> URL {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".ok"), withIntermediateDirectories: true)
        return vault
    }

    private func idea(title: String = "Venda B2B por encomenda", id: UUID? = nil) -> IdeaNote {
        IdeaNote(id: id ?? self.id, createdAt: date, title: title,
                 text: "Tive uma ideia: vender B2B por encomenda.\nSegunda linha.", tags: ["vendas", "ideia"],
                 original: "tem uma ideia vender btubi em comenda\n")
    }

    @Test func ideaRendersOKFrontmatterAndLandsInInbox() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let url = try OKInbox.writeIdea(idea(), to: vault, timeZone: utc)
        #expect(url.path.hasSuffix("_inbox/ideias/2026-10-14-venda-b2b-por-encomenda.md"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(OKFrontmatter.scalar("type", in: text) == "ideia")
        #expect(OKFrontmatter.scalar("description", in: text) == "Tive uma ideia: vender B2B por encomenda.")
        #expect(FileManager.default.fileExists(atPath: vault.appendingPathComponent("_inbox/.ok/frontmatter.yml").path))
    }

    @Test func rendersIdea() {
        #expect(OKInbox.renderIdea(idea(title: #"Venda "B2B""#), timeZone: utc) == """
        ---
        id: 00000000-0000-0000-0000-000000000079
        title: "Venda \\"B2B\\""
        description: "Tive uma ideia: vender B2B por encomenda."
        type: ideia
        date: 2026-10-14
        created: 2026-10-14T14:32:00+00:00
        tags: [ideia, vendas]
        ---

        Tive uma ideia: vender B2B por encomenda.
        Segunda linha.

        ## Transcrição original

        tem uma ideia vender btubi em comenda

        """)
    }

    @Test func descriptionIsCappedAndQuoted() {
        var long = idea()
        long.text = "  \n" + String(repeating: "é\"", count: 100) + "\nfim"
        let text = OKInbox.renderIdea(long, timeZone: utc)
        #expect(OKFrontmatter.isWellFormed(text))
        #expect(OKFrontmatter.scalar("description", in: text) == String(String(repeating: "é\"", count: 100).prefix(160)))
    }

    @Test func ideaFileNameFallsBackAndNeverOverwritesAnotherIdea() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let first = try OKInbox.writeIdea(idea(title: "✨✨"), to: vault, timeZone: utc)
        #expect(first.lastPathComponent == "2026-10-14-ideia.md")
        #expect(try OKInbox.writeIdea(idea(title: "✨✨"), to: vault, timeZone: utc) == first) // same id: idempotent
        let other = try OKInbox.writeIdea(idea(title: "!!!", id: UUID()), to: vault, timeZone: utc)
        #expect(other.lastPathComponent == "2026-10-14-ideia-2.md")
    }

    @Test func dailyGetsOKHeaderAndRelativeLink() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let ideaURL = try OKInbox.writeIdea(idea(), to: vault, timeZone: utc)
        let daily = try OKInbox.appendToDaily(OKInbox.link(toIdea: ideaURL, title: "Venda [B2B]", vault: vault),
                                              at: date, to: vault, timeZone: utc)
        #expect(daily == OKInbox.dailyURL(in: vault, for: date, timeZone: utc))
        #expect(daily.path.hasSuffix("_inbox/diario/2026-10-14.md"))
        let text = try String(contentsOf: daily, encoding: .utf8)
        #expect(text == """
        ---
        title: "Diário 2026-10-14"
        description: "Notas de voz de 2026-10-14."
        type: diario
        date: 2026-10-14
        tags: [diario]
        ---

        ## Ideias

        - 14:32 [Venda B2B](../ideias/2026-10-14-venda-b2b-por-encomenda.md)

        """)
        #expect(!text.contains("[["))
    }

    @Test func linkStripsBracketsAndParentheses() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let url = vault.appendingPathComponent("_inbox/ideias/2026-10-14-x.md")
        #expect(OKInbox.link(toIdea: url, title: "a (b) [c]\nd", vault: vault) == "[a b c d](../ideias/2026-10-14-x.md)")
        #expect(OKInbox.link(toIdea: url, title: "[]()", vault: vault) == "[ideia](../ideias/2026-10-14-x.md)")
    }

    @Test func dailyAppendsToExistingNoteWithoutTouchingIt() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try OKInbox.appendToDaily("primeira", at: date, to: vault, timeZone: utc)
        let daily = try OKInbox.appendToDaily("segunda\nlinha", at: date.addingTimeInterval(60), to: vault, timeZone: utc)
        let text = try String(contentsOf: daily, encoding: .utf8)
        #expect(text.hasSuffix("## Ideias\n\n- 14:32 primeira\n- 14:33 segunda\n  linha\n"))
        #expect(text.components(separatedBy: "type: diario").count == 2)
    }

    @Test func inboxMetadataIsCreatedOnce() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try OKInbox.appendToDaily("x", at: date, to: vault, timeZone: utc)
        let meta = vault.appendingPathComponent("_inbox/.ok/frontmatter.yml")
        #expect(try String(contentsOf: meta, encoding: .utf8)
            == "title: Inbox\ndescription: Notas de voz do VoiceType (diário e ideias), fora dos projetos.\ntags:\n  - inbox\n")
        let staging = vault.appendingPathComponent(".ok/local/voicetype-staging")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? [] == [])
    }

    @Test func inboxMetadataIsNeverOverwritten() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let meta = vault.appendingPathComponent("_inbox/.ok/frontmatter.yml")
        try FileManager.default.createDirectory(at: meta.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("title: Meu\n".utf8).write(to: meta)
        try OKInbox.writeIdea(idea(), to: vault, timeZone: utc)
        try OKInbox.appendToDaily("x", at: date, to: vault, timeZone: utc)
        #expect(try String(contentsOf: meta, encoding: .utf8) == "title: Meu\n")
    }

    private struct Interrupted: Error {}

    /// Regular files the OK auto-commit could see: everything but `.ok/local/`.
    private func contentFiles(_ vault: URL) -> [String] {
        let all = FileManager.default.enumerator(atPath: vault.path)?.compactMap { $0 as? String } ?? []
        return all.filter { rel in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: vault.appendingPathComponent(rel).path, isDirectory: &isDirectory)
            return !isDirectory.boolValue && !rel.hasPrefix(".ok/local/")
        }.sorted()
    }

    private func staging(_ vault: URL) -> URL {
        vault.appendingPathComponent(".ok/local/voicetype-staging", isDirectory: true)
    }

    @Test func ideaIsStagedOutsideContentFoldersUntilTheRename() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let rendered = OKInbox.renderIdea(idea(), timeZone: utc)
        #expect(throws: Interrupted.self) {
            try OKInbox.writeIdea(idea(), to: vault, timeZone: utc, beforeRename: { tmp in
                #expect(tmp.deletingLastPathComponent().path == staging(vault).path)
                #expect(try String(contentsOf: tmp, encoding: .utf8) == rendered)
                #expect(contentFiles(vault) == ["_inbox/.ok/frontmatter.yml"])
                throw Interrupted()
            })
        }
        #expect(contentFiles(vault) == ["_inbox/.ok/frontmatter.yml"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging(vault).path) == [])

        let url = try OKInbox.writeIdea(idea(), to: vault, timeZone: utc)
        #expect(try String(contentsOf: url, encoding: .utf8) == rendered)
        #expect(contentFiles(vault) == ["_inbox/.ok/frontmatter.yml", "_inbox/ideias/2026-10-14-venda-b2b-por-encomenda.md"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging(vault).path) == [])
    }

    @Test func dailyIsStagedOutsideContentFoldersUntilTheRename() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let daily = try OKInbox.appendToDaily("primeira", at: date, to: vault, timeZone: utc)
        let before = try String(contentsOf: daily, encoding: .utf8)
        let files = ["_inbox/.ok/frontmatter.yml", "_inbox/diario/2026-10-14.md"]
        #expect(contentFiles(vault) == files)

        #expect(throws: Interrupted.self) {
            try OKInbox.appendToDaily("segunda", at: date, to: vault, timeZone: utc, beforeRename: { tmp in
                #expect(tmp.deletingLastPathComponent().path == staging(vault).path)
                #expect(try String(contentsOf: tmp, encoding: .utf8) == before + "- 14:32 segunda\n")
                #expect(try String(contentsOf: daily, encoding: .utf8) == before)
                #expect(contentFiles(vault) == files)
                throw Interrupted()
            })
        }
        #expect(try String(contentsOf: daily, encoding: .utf8) == before)
        #expect(contentFiles(vault) == files)
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging(vault).path) == [])
    }

    @Test func dailySavedBetweenReadAndRenameKeepsBothVersions() throws {
        for atomic in [false, true] {
            let vault = try makeVault()
            defer { try? FileManager.default.removeItem(at: vault) }
            let daily = try OKInbox.appendToDaily("anterior", at: date, to: vault, timeZone: utc)
            let before = try String(contentsOf: daily, encoding: .utf8)
            var attempts = 0
            _ = try OKInbox.appendToDaily("nova", at: date, to: vault, timeZone: utc, beforeRename: { _ in
                attempts += 1
                if attempts == 1 {
                    try Data((before + "\nEdição manual concorrente\n").utf8).write(to: daily, options: atomic ? .atomic : [])
                }
            })
            let text = try String(contentsOf: daily, encoding: .utf8)
            #expect(attempts == 2, "atomic: \(atomic)")
            #expect(text == before + "\nEdição manual concorrente\n- 14:32 nova\n", "atomic: \(atomic)")
            #expect(try FileManager.default.contentsOfDirectory(atPath: staging(vault).path) == [])
            // Both swaps of the first attempt and the swap of the second took a version out of the daily: none is deleted.
            let first = try String(contentsOf: daily, encoding: .utf8).replacingOccurrences(of: "\nEdição manual concorrente\n", with: "")
            #expect(preservedTexts(vault) == [first, before + "\nEdição manual concorrente\n"].sorted(), "atomic: \(atomic)")
        }
    }

    /// The contents of `.ok/local/voicetype-preserved/inbox/`, sorted.
    private func preservedTexts(_ vault: URL) -> [String] {
        let dir = vault.appendingPathComponent(".ok/local/voicetype-preserved/inbox")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }.sorted()
    }

    private func stagedTexts(_ vault: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: staging(vault).path)) ?? []
        return names.compactMap { try? String(contentsOf: staging(vault).appendingPathComponent($0), encoding: .utf8) }.sorted()
    }

    @Test func dailyRestoreFailureKeepsTheOutsideVersion() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let daily = try OKInbox.appendToDaily("anterior", at: date, to: vault, timeZone: utc)
        let before = try String(contentsOf: daily, encoding: .utf8)
        let outside = before + "\nEdição manual concorrente\n"
        var kept: String?
        do {
            _ = try OKInbox.appendToDaily("nova", at: date, to: vault, timeZone: utc, beforeRename: { _ in
                try Data(outside.utf8).write(to: daily, options: .atomic)
            }, fault: { step in
                if step == .restore { throw POSIXError(.EIO) }
            })
            Issue.record("esperava outsideVersionKept")
        } catch let OKInbox.AppendError.outsideVersionKept(path) {
            kept = path
        }
        let path = try #require(kept)
        #expect(path.contains("/.ok/local/voicetype-preserved/inbox/"))
        #expect(try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) == outside)
        #expect(OKInbox.AppendError.outsideVersionKept(path).localizedDescription.contains(path))
        #expect(try String(contentsOf: daily, encoding: .utf8) == before + "- 14:32 nova\n")
        #expect(preservedTexts(vault) == [outside])
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging(vault).path) == [])
    }

    @Test func dailyPreservationFailureLeavesTheVersionsInTheStaging() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let daily = try OKInbox.appendToDaily("anterior", at: date, to: vault, timeZone: utc)
        let before = try String(contentsOf: daily, encoding: .utf8)
        let outside = before + "\nEdição manual concorrente\n"
        var attempts = 0
        _ = try OKInbox.appendToDaily("nova", at: date, to: vault, timeZone: utc, beforeRename: { _ in
            attempts += 1
            if attempts == 1 { try Data(outside.utf8).write(to: daily, options: .atomic) }
        }, fault: { step in
            if step == .preserve { throw POSIXError(.EIO) }
        })
        #expect(attempts == 2)
        #expect(try String(contentsOf: daily, encoding: .utf8) == outside + "- 14:32 nova\n")
        #expect(stagedTexts(vault) == [before + "- 14:32 nova\n", outside].sorted())
        #expect(preservedTexts(vault) == [])
    }

    @Test func dailyWrittenThroughAnOpenDescriptorSurvives() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let daily = try OKInbox.appendToDaily("anterior", at: date, to: vault, timeZone: utc)
        let before = try String(contentsOf: daily, encoding: .utf8)
        let editor = try FileHandle(forUpdating: daily)
        defer { try? editor.close() }
        func write(_ text: String) throws {
            try editor.truncate(atOffset: 0)
            try editor.write(contentsOf: Data(text.utf8))
            try editor.synchronize()
        }

        // During the append, after the swap took the editor's inode out of the
        // daily: the change is seen, put back and the entry inserted into it.
        let during = before + "\nPelo descritor, durante\n"
        var wrote = false
        _ = try OKInbox.appendToDaily("nova", at: date, to: vault, timeZone: utc, beforeRename: nil, fault: { step in
            if step == .preserve, !wrote {
                wrote = true
                try write(during)
            }
        })
        #expect(try String(contentsOf: daily, encoding: .utf8) == during + "- 14:32 nova\n")

        // After the append returned: the editor's inode is out of the daily
        // again, and what it writes lands in a kept file.
        let after = before + "\nPelo descritor, depois\n"
        try write(after)
        #expect(preservedTexts(vault).contains(after))
        #expect(try String(contentsOf: daily, encoding: .utf8) == during + "- 14:32 nova\n")
    }

    @Test func dailyWriterWhoseDescriptorMovesSurvives() throws {
        // The editor's descriptor moves to another number while the append
        // takes its inode out of the daily: the version is kept anyway, and
        // a write after the append lands in the kept copy.
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let daily = try OKInbox.appendToDaily("anterior", at: date, to: vault, timeZone: utc)
        let before = try String(contentsOf: daily, encoding: .utf8)
        var fd = open(daily.path, O_RDWR)
        try #require(fd >= 0)
        defer { close(fd) }
        _ = try OKInbox.appendToDaily("nova", at: date, to: vault, timeZone: utc, beforeRename: nil, fault: { step in
            if step == .preserve {
                let moved = dup(fd)
                close(fd)
                fd = moved
            }
        })
        #expect(try String(contentsOf: daily, encoding: .utf8) == before + "- 14:32 nova\n")
        #expect(preservedTexts(vault) == [before])

        let after = before + "\nPelo descritor movido\n"
        #expect(ftruncate(fd, 0) == 0)
        #expect(pwrite(fd, after, after.utf8.count, 0) == after.utf8.count)
        fsync(fd)
        #expect(preservedTexts(vault) == [after])
    }

    @Test func dailyCreatedBetweenReadAndRenameIsNotReplaced() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let daily = OKInbox.dailyURL(in: vault, for: date, timeZone: utc)
        let manual = "---\ntitle: Diário manual\n---\n\nEscrito à mão.\n"
        var attempts = 0
        _ = try OKInbox.appendToDaily("nova", at: date, to: vault, timeZone: utc, beforeRename: { _ in
            attempts += 1
            if attempts == 1 { try Data(manual.utf8).write(to: daily) }
        })
        #expect(attempts == 2)
        #expect(try String(contentsOf: daily, encoding: .utf8) == manual + "\n## Ideias\n\n- 14:32 nova\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging(vault).path) == [])
    }

    @Test func dailyThatKeepsChangingIsNeverOverwritten() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let daily = try OKInbox.appendToDaily("anterior", at: date, to: vault, timeZone: utc)
        var attempts = 0
        #expect(throws: OKInbox.AppendError.dailyKeepsChanging) {
            try OKInbox.appendToDaily("nova", at: date, to: vault, timeZone: utc, beforeRename: { _ in
                attempts += 1
                try Data("Versão \(attempts)\n".utf8).write(to: daily)
            })
        }
        #expect(attempts == OKInbox.dailyAttempts)
        #expect(try String(contentsOf: daily, encoding: .utf8) == "Versão \(OKInbox.dailyAttempts)\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging(vault).path) == [])
        #expect(preservedTexts(vault).count == OKInbox.dailyAttempts)
    }

    @Test func obsidianDailyHeaderUnchanged() {
        #expect(DailyNote.inserting("Ideia nova", at: date, into: nil, timeZone: utc) == """
        ---
        type: daily
        date: 2026-10-14
        tags: [daily]
        ---

        ## Ideias

        - 14:32 Ideia nova

        """)
        #expect(DailyNote.inserting("Ideia nova", at: date, into: nil, timeZone: utc, newFileHeader: "# H\n\n")
            == "# H\n\n## Ideias\n\n- 14:32 Ideia nova\n")
        #expect(DailyNote.inserting("x", at: date, into: "# Meu\n", timeZone: utc, newFileHeader: "# H\n\n")
            == "# Meu\n\n## Ideias\n\n- 14:32 x\n")
    }
}
