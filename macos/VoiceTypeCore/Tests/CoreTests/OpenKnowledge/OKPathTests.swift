import Foundation
import Testing
@testable import Core

@Suite("OKPath")
struct OKPathTests {

    @Test func knowledgeDocRejectsEscapesAndNonTypeFolders() {
        #expect(OKPath.knowledgeDoc("p5/decisoes/x.md", project: "p5")! == (.decisao, "x.md"))
        for bad in ["p5/../x/decisoes/a.md", "/p5/decisoes/a.md", "p5/decisoes/a.txt", "p5/reunioes/a.md",
                    "p6/decisoes/a.md", "p5/decisoes/sub/a.md", "p5/decisoes/.a.md", "p5\\decisoes\\a.md", "p5/decisoes/"] {
            #expect(OKPath.knowledgeDoc(bad, project: "p5") == nil, "\(bad)")
        }
        for bad in ["p5/decisoes/.md", "p5//decisoes/a.md", "p5/decisoes/a.md/", "./p5/decisoes/a.md", "p5/decisoes/a\n.md"] {
            #expect(OKPath.knowledgeDoc(bad, project: "p5") == nil, "\(bad)")
        }
        #expect(OKPath.knowledgeDoc("p5/glossario/sla.md", project: "p5")! == (.termo, "sla.md"))
    }

    @Test func relativeLinksBetweenVaultPaths() {
        #expect(OKPath.relativeLink(from: "p5/decisoes/a.md", to: "p5/reunioes/2026-10-16-x.md") == "../reunioes/2026-10-16-x.md")
        #expect(OKPath.relativeLink(from: "p5/reunioes/x.md", to: "p5/reunioes/transcricoes/x.md") == "transcricoes/x.md")
        #expect(OKPath.relativeLink(from: "p5/reunioes/transcricoes/x.md", to: "p5/reunioes/x.md") == "../x.md")
        #expect(OKPath.relativeLink(from: "_inbox/diario/d.md", to: "_inbox/ideias/i.md") == "../ideias/i.md")
        #expect(OKPath.relativeLink(from: "README.md", to: "p5/index.md") == "p5/index.md")
        #expect(OKPath.relativeLink(from: "p5/index.md", to: "p5/decisoes/a.md") == "decisoes/a.md")
        #expect(OKPath.relativeLink(from: "p5/decisoes/a.md", to: "p5/decisoes/b.md") == "b.md")
        #expect(OKPath.relativeLink(from: "p5/decisoes/a.md", to: "p6/decisoes/b.md") == "../../p6/decisoes/b.md")
    }

    @Test func uniqueDestinationUsesDashSuffixAndReusesOwnFile() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let id = UUID()

        #expect(OKPath.uniqueDestination(base: "2026-10-16-daily", id: id, in: dir).lastPathComponent == "2026-10-16-daily.md")

        try Data("---\nid: \(UUID().uuidString)\n---\nb\n".utf8).write(to: dir.appendingPathComponent("2026-10-16-daily.md"))
        #expect(OKPath.uniqueDestination(base: "2026-10-16-daily", id: id, in: dir).lastPathComponent == "2026-10-16-daily-2.md")

        try Data("sem frontmatter\n".utf8).write(to: dir.appendingPathComponent("2026-10-16-daily-2.md"))
        #expect(OKPath.uniqueDestination(base: "2026-10-16-daily", id: id, in: dir).lastPathComponent == "2026-10-16-daily-3.md")

        try Data("---\ntitle: x\nid: \(id.uuidString)\n---\nb\n".utf8).write(to: dir.appendingPathComponent("2026-10-16-daily-2.md"))
        #expect(OKPath.uniqueDestination(base: "2026-10-16-daily", id: id, in: dir).lastPathComponent == "2026-10-16-daily-2.md")

        try Data("---\nid: \(id.uuidString)\n---\nb\n".utf8).write(to: dir.appendingPathComponent("2026-10-16-daily.md"))
        #expect(OKPath.uniqueDestination(base: "2026-10-16-daily", id: id, in: dir).lastPathComponent == "2026-10-16-daily.md")
    }

    @Test func contentHashIsSHA256Hex() {
        #expect(OKPath.contentHash(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(OKPath.contentHash(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
