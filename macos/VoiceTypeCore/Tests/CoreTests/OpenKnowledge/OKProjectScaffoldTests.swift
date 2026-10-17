import Foundation
import Testing
@testable import Core

@Suite("OKProjectScaffold")
struct OKProjectScaffoldTests {

    /// Excerpt of a real OpenKnowledge project index (2026-10-16): `### Decisões (ADR)`
    /// in the middle, `### Glossário` last.
    private let p5Index = """
    ---
    title: p5 — visão geral
    description: Índice do conhecimento do projeto p5 (Intranet Document Management / orquestrador FileNet).
    type: indice
    project: p5
    tags:
      - indice
      - p5
    ---
    # p5 — visão geral

    **P5** é a intranet de gestão documental e de processos.

    ## Conhecimento registrado

    ### Arquitetura
    - [Visão geral — orquestrador sobre FileNet](./arquitetura/visao-geral.md)
    - [Integração com o IBM FileNet](./arquitetura/integracao-filenet.md)

    ### Decisões (ADR)
    - [Orquestrador sobre FileNet (sem espelho local)](./decisoes/orquestrador-sobre-filenet.md)
    - [Tipos de comentário data-driven](./decisoes/comment-types-data-driven.md)

    ### Regras de negócio
    - [Identidades de um documento (docId/document_id/vsId)](./regras-de-negocio/identidades-de-documento.md)

    ### Glossário
    - [Dossier](./glossario/dossier.md)
    - [CLAV e MEF](./glossario/clav-e-mef.md)

    """

    @Test func folderMetadataCoversNineFolders() {
        let files = OKProjectScaffold.folderMetadata(project: "acme")
        #expect(files.count == 9 && files.contains { $0.path == "acme/reunioes/.ok/frontmatter.yml" && $0.content == "title: Reuniões — acme\ndescription: Registros de reuniões do acme, gravados pelo VoiceType.\ntags:\n  - reuniao\n  - acme\n" })
        #expect(files.contains { $0.path == "acme/decisoes/.ok/frontmatter.yml" && $0.content.hasPrefix("title: Decisões (ADR) — acme\n") })
        #expect(files.contains { $0.path == "acme/decisoes/.ok/frontmatter.yml" && $0.content == "title: Decisões (ADR) — acme\ndescription: Registro de decisões arquiteturais do acme.\ntags:\n  - decisao\n  - acme\n" })
        #expect(files.contains { $0.path == "acme/reunioes/transcricoes/.ok/frontmatter.yml" && $0.content == "title: Transcrições — acme\ndescription: Transcrições brutas das reuniões do acme (fonte não confiável).\ntags:\n  - transcricao\n  - acme\n" })
        #expect(Set(files.map(\.path)).count == 9)
        for type in OKKnowledgeType.allCases {
            #expect(files.contains { $0.path == "acme/\(type.folder)/.ok/frontmatter.yml" })
        }
    }

    @Test func indexMatchesNovoProjetoSkill() {
        let index = OKProjectScaffold.index(project: "acme", description: "API de cobrança da Acme.")
        #expect(index == OKFileWrite(path: "acme/index.md", content: """
        ---
        title: "acme — visão geral"
        description: "Índice do conhecimento do projeto acme."
        type: indice
        project: acme
        tags: [indice, acme]
        ---

        # acme — visão geral

        API de cobrança da Acme.

        ## Conhecimento registrado

        _Links aparecem aqui conforme docs são criados._

        """))
        #expect(OKFrontmatter.scalar("type", in: index.content) == "indice")
    }

    @Test func readmeGetsProjectAfterLastItem() {
        let readme = "# Vault\n\n## Projetos\n\n- [p5 — X](./p5/index.md)\n\n_Novos projetos entram aqui._\n\n## Regras\n\n- uma\n"
        #expect(OKProjectScaffold.readmeAddingProject(readme, project: "acme", description: "Cobrança [beta]") ==
            "# Vault\n\n## Projetos\n\n- [p5 — X](./p5/index.md)\n- [acme — Cobrança \\[beta\\]](./acme/index.md)\n\n_Novos projetos entram aqui._\n\n## Regras\n\n- uma\n")
    }

    @Test func readmeWithoutProjectsSectionGetsOne() {
        #expect(OKProjectScaffold.readmeAddingProject("# Vault\n\nTexto.\n", project: "acme", description: "Acme") ==
            "# Vault\n\nTexto.\n\n## Projetos\n\n- [acme — Acme](./acme/index.md)\n")
    }

    @Test func readmeAlreadyListingProjectIsUnchanged() {
        let readme = "## Projetos\n\n- [acme — Acme](./acme/index.md)\n"
        #expect(OKProjectScaffold.readmeAddingProject(readme, project: "acme", description: "Outra") == readme)
    }

    @Test func indexLinksGoToMatchingSubsectionWithoutDuplicates() {
        let links: [(type: OKKnowledgeType, title: String, path: String)] = [
            (.decisao, "Nova", "p5/decisoes/nova.md"),
            (.termo, "T", "p5/glossario/t.md"),
        ]
        let once = OKProjectScaffold.indexAddingLinks(p5Index, links: links)
        #expect(once.contains("- [Tipos de comentário data-driven](./decisoes/comment-types-data-driven.md)\n- [Nova](./decisoes/nova.md)\n\n### Regras de negócio"))
        #expect(once.hasSuffix("- [CLAV e MEF](./glossario/clav-e-mef.md)\n- [T](./glossario/t.md)\n"))
        #expect(OKProjectScaffold.indexAddingLinks(once, links: links) == once)
        #expect(once.components(separatedBy: "\n").count == p5Index.components(separatedBy: "\n").count + 2)
    }

    @Test func decisionsHeadingWithoutADRSuffixIsAccepted() {
        let index = "# x\n\n## Conhecimento registrado\n\n### Decisões\n- [A](./decisoes/a.md)\n"
        #expect(OKProjectScaffold.indexAddingLinks(index, links: [(.decisao, "B", "x/decisoes/b.md")]) ==
            "# x\n\n## Conhecimento registrado\n\n### Decisões\n- [A](./decisoes/a.md)\n- [B](./decisoes/b.md)\n")
    }

    @Test func freshIndexDropsPlaceholderAndCreatesSubsection() {
        let fresh = OKProjectScaffold.index(project: "acme", description: "Acme.").content
        let out = OKProjectScaffold.indexAddingLinks(fresh, links: [(.gotcha, "G", "acme/gotchas/g.md")])
        #expect(out.contains("### Gotchas\n\n- [G](./gotchas/g.md)"))
        #expect(!out.contains("_Links aparecem"))
        #expect(out.hasSuffix("## Conhecimento registrado\n\n### Gotchas\n\n- [G](./gotchas/g.md)\n"))
    }

    @Test func missingSubsectionIsCreatedBeforeTheNextSection() {
        let index = "# x\n\n## Conhecimento registrado\n\n### Arquitetura\n- [A](./arquitetura/a.md)\n\n## Outros\n\ntexto\n"
        #expect(OKProjectScaffold.indexAddingLinks(index, links: [(.snippet, "S [1]", "x/snippets/s.md")]) ==
            "# x\n\n## Conhecimento registrado\n\n### Arquitetura\n- [A](./arquitetura/a.md)\n\n### Snippets\n\n- [S \\[1\\]](./snippets/s.md)\n\n## Outros\n\ntexto\n")
    }

    @Test func indexWithoutSectionGetsItAtTheEnd() {
        #expect(OKProjectScaffold.indexAddingLinks("# x\n\nTexto.\n", links: [(.tutorial, "Setup", "x/tutoriais/setup.md")]) ==
            "# x\n\nTexto.\n\n## Conhecimento registrado\n\n### Tutoriais\n\n- [Setup](./tutoriais/setup.md)\n")
    }
}
