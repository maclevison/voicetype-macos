import Foundation
import Testing
@testable import Core

@Suite("OKVaultCatalog")
struct OKVaultCatalogTests {

    private func makeVault() throws -> URL {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        return vault
    }

    private func write(_ text: String, _ relPath: String, in vault: URL) throws {
        let url = vault.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private let utc = TimeZone(identifier: "UTC")!
    private let date = Date(timeIntervalSince1970: 1_792_152_000) // 2026-10-16T12:00:00Z

    @Test func projectsAreRootFoldersWithIndiceIndex() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try write("---\ntitle: p5 — visão geral\ndescription: Índice do p5.\ntype: indice\nproject: p5\ntags:\n  - indice\n---\n# p5\n", "p5/index.md", in: vault)
        try write("---\ntitle: Convenções\ntype: guia\n---\n", "guia/convencoes.md", in: vault)
        try write("---\ntitle: Inbox\ntype: indice\n---\n", "_inbox/index.md", in: vault)
        try write("---\ntitle: OK\ntype: indice\n---\n", ".ok/index.md", in: vault)
        try write("---\ntitle: x\n---\n", "x/index.md", in: vault)
        try write("---\ntitle: Bad\ntype: indice\n---\n", "Bad Name/index.md", in: vault)
        try write("---\ntitle: README\ntype: indice\n---\n", "README.md", in: vault)

        let projects = try OKVaultCatalog.projects(in: vault)
        #expect(projects.map(\.slug) == ["p5"])
        #expect(projects[0].title == "p5 — visão geral")
        #expect(projects[0].description == "Índice do p5.")
        #expect(projects[0].id == "p5")
    }

    @Test func projectsAreSortedBySlugWithFallbackTitle() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try write("---\ntype: indice\n---\n", "zeta/index.md", in: vault)
        try write("---\ntitle: Alfa\ntype: indice\ndescription: 'D'\n---\n", "alfa/index.md", in: vault)

        let projects = try OKVaultCatalog.projects(in: vault)
        #expect(projects == [OKProject(slug: "alfa", title: "Alfa", description: "D"),
                             OKProject(slug: "zeta", title: "zeta", description: "")])
    }

    @Test func docsListOnlyMarkdownDirectlyInTypeFolders() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try write("---\ntitle: Usar X\ndescription: Decidimos X.\ntype: decisao\n---\nb\n", "p5/decisoes/a.md", in: vault)
        try write("title: Decisões (ADR) — p5\n", "p5/decisoes/.ok/frontmatter.yml", in: vault)
        try write("---\ntitle: Escondido\n---\n", "p5/decisoes/.oculto.md", in: vault)
        try write("não é markdown\n", "p5/decisoes/notas.txt", in: vault)
        try write("---\ntitle: R\n---\n", "p5/reunioes/r.md", in: vault)
        try write("---\ntitle: B\n---\n", "p5/decisoes/sub/b.md", in: vault)
        try write("sem frontmatter\n", "p5/gotchas/g.md", in: vault)
        try write("---\ntitle: Outro\n---\n", "p6/decisoes/c.md", in: vault)

        let docs = try OKVaultCatalog.docs(project: "p5", in: vault)
        #expect(docs.map(\.path) == ["p5/decisoes/a.md", "p5/gotchas/g.md"])
        #expect(docs[0].type == .decisao && docs[1].type == .gotcha)
        #expect(docs[0].title == "Usar X" && docs[0].description == "Decidimos X.")
        #expect(docs[1].title == "g" && docs[1].description == "")
        #expect(docs[0].hash == OKPath.contentHash(try Data(contentsOf: vault.appendingPathComponent("p5/decisoes/a.md"))))
    }

    @Test func docsOfProjectWithoutTypeFoldersIsEmpty() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try write("---\ntype: indice\n---\n", "p5/index.md", in: vault)
        #expect(try OKVaultCatalog.docs(project: "p5", in: vault).isEmpty)
    }

    @Test func repeatedKeysReadAsMissing() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try write("---\ntype: indice\ntitle: P5\ntype: indice\n---\n", "p5/index.md", in: vault)
        try write("---\ntype: indice\ntitle: A\ntitle: B\n---\n", "p6/index.md", in: vault)
        try write("---\ntitle: A\ndescription: X\ntitle: B\ndescription: Y\n---\n", "p6/decisoes/dup.md", in: vault)
        // Quoted or spaced spellings are the same key: repeated, and read when alone.
        try write("---\ntype: indice\n\"type\": indice\n---\n", "p7/index.md", in: vault)
        try write("---\n'type' : indice\n\"title\": Oito\n---\n", "p8/index.md", in: vault)
        try write("---\ntitle: A\n'title': B\n---\n", "p6/gotchas/quoted.md", in: vault)

        #expect(try OKVaultCatalog.projects(in: vault) == [OKProject(slug: "p6", title: "p6", description: ""),
                                                          OKProject(slug: "p8", title: "Oito", description: "")])
        let docs = try OKVaultCatalog.docs(project: "p6", in: vault)
        #expect(docs.map(\.title) == ["dup", "quoted"] && docs.map(\.description) == ["", ""])
    }

    @Test func fingerprintChangesWithAnyDocHash() {
        let a = OKDocEntry(path: "p5/decisoes/a.md", type: .decisao, title: "A", description: "", hash: "1")
        let b = OKDocEntry(path: "p5/gotchas/b.md", type: .gotcha, title: "B", description: "", hash: "2")
        var b2 = b
        b2.hash = "3"
        var aRetitled = a
        aRetitled.title = "Outro"

        #expect(OKVaultCatalog.fingerprint([a, b]) == OKVaultCatalog.fingerprint([b, a]))
        #expect(OKVaultCatalog.fingerprint([a, b]) == OKVaultCatalog.fingerprint([aRetitled, b]))
        #expect(OKVaultCatalog.fingerprint([a, b]) != OKVaultCatalog.fingerprint([a, b2]))
        #expect(OKVaultCatalog.fingerprint([a, b]) != OKVaultCatalog.fingerprint([a]))
        #expect(OKVaultCatalog.fingerprint([]).count == 64)
    }

    @Test func templateStripsTemplateBlockAndFillsPlaceholders() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try write(Self.decisaoTemplate, ".ok/templates/decisao.md", in: vault)

        let t = try OKTemplate.load(.decisao, vault: vault, date: date, user: "Felipe Reis", timeZone: utc)
        #expect(OKFrontmatter.scalar("template", in: t) == nil && !t.contains("\n  title: Decisão (ADR)"))
        #expect(t.contains("date: '2026-10-16'") && t.contains("Autor: Felipe Reis") && !t.contains("{{"))
        #expect(t.hasPrefix("---\ntitle: 'TODO — título da decisão'\n"))
        #expect(OKFrontmatter.scalar("type", in: t) == "decisao")
    }

    @Test func templateDropsEveryTemplateBlock() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try write("---\ntemplate:\n  title: A\ntitle: TODO\ntemplate:\n  title: B\n'template' :\n  title: C\n---\nb\n", ".ok/templates/termo.md", in: vault)
        #expect(try OKTemplate.load(.termo, vault: vault, date: date, user: "u", timeZone: utc) == "---\ntitle: TODO\n---\nb\n")
    }

    @Test func templateDateFollowsTimeZone() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try write("---\ndate: '{{date}}'\n---\n{{date}}\n", ".ok/templates/gotcha.md", in: vault)

        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let late = Date(timeIntervalSince1970: 1_792_195_200) // 2026-10-17T00:00:00Z
        #expect(try OKTemplate.load(.gotcha, vault: vault, date: late, user: "u", timeZone: utc) == "---\ndate: '2026-10-17'\n---\n2026-10-17\n")
        #expect(try OKTemplate.load(.gotcha, vault: vault, date: date, user: "u", timeZone: tokyo) == "---\ndate: '2026-10-16'\n---\n2026-10-16\n")
    }

    @Test func missingTemplateThrowsNoSuchFile() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        #expect {
            try OKTemplate.load(.snippet, vault: vault, date: date, user: "u", timeZone: utc)
        } throws: { ($0 as? CocoaError)?.code == .fileReadNoSuchFile }
    }

    /// Exact text of a real OpenKnowledge `.ok/templates/decisao.md`.
    private static let decisaoTemplate = """
    ---
    template:
      title: Decisão (ADR)
      description: "Registro de decisão arquitetural: contexto → decisão →
        consequências → alternativas."
      tags:
        - decisao
        - adr
    title: 'TODO — título da decisão'
    description: 'TODO — resumo da decisão em uma linha'
    type: decisao
    project: TODO
    status: proposta
    date: '{{date}}'
    deciders: []
    supersedes: ''
    tags: [decisao, adr]
    ---

    > [!info] Status: **proposta** · Data: {{date}} · Autor: {{user}}
    > Estados possíveis: `proposta` → `aceita` → `substituida` / `descartada`.

    ## Contexto

    _Qual força/problema motivou a decisão? Restrições, requisitos e trade-offs em jogo._

    ## Decisão

    _A escolha feita, em uma frase afirmativa: "Vamos usar X para Y"._

    ## Consequências

    **Positivas**
    - _..._

    **Negativas / custos**
    - _..._

    ## Alternativas consideradas

    | Alternativa | Prós | Contras | Por que não |
    | --- | --- | --- | --- |
    | _..._ | _..._ | _..._ | _..._ |

    ## Fontes

    - _(TODO: cite a fonte — ticket, thread ingerida, doc relacionado)_

    ## Relacionados

    - _(links para arquitetura, regras de negócio ou decisões que esta substitui)_

    """
}
