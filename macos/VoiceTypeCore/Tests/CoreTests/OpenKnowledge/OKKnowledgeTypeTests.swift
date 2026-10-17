import Foundation
import Testing
@testable import Core

@Suite("OKKnowledgeType")
struct OKKnowledgeTypeTests {

    @Test func typeTableMatchesVault() {
        #expect(OKKnowledgeType.decisao.folderTitle(project: "p5") == "Decisões (ADR) — p5")
        #expect(OKKnowledgeType(folder: "glossario") == .termo && OKKnowledgeType(folder: "reunioes") == nil)
        #expect(OKKnowledgeType.allCases.map(\.folder) == ["decisoes","regras-de-negocio","arquitetura","tutoriais","gotchas","glossario","snippets"])
    }

    @Test func headingsDescriptionsTagsAndTemplates() {
        #expect(OKKnowledgeType.allCases.map(\.indexHeading) == ["Decisões (ADR)", "Regras de negócio", "Arquitetura", "Tutoriais", "Gotchas", "Glossário", "Snippets"])
        #expect(OKKnowledgeType.allCases.map(\.templateName) == ["decisao", "regra-de-negocio", "arquitetura", "tutorial", "gotcha", "termo", "snippet"])
        #expect(OKKnowledgeType.regraDeNegocio.folderTitle(project: "p5") == "Regras de negócio — p5")
        #expect(OKKnowledgeType.regraDeNegocio.folderDescription(project: "p5") == "Regras de domínio, invariantes e políticas do p5.")
        #expect(OKKnowledgeType.snippet.folderDescription(project: "p5") == "Código reutilizável e padrões do p5.")
        #expect(OKKnowledgeType.termo.folderTags(project: "p5") == ["termo", "p5"])
        for type in OKKnowledgeType.allCases { #expect(OKKnowledgeType(folder: type.folder) == type) }
    }
}
