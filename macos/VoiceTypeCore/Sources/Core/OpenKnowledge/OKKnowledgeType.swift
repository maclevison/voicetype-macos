import Foundation

/// The seven knowledge types of an OpenKnowledge project. Folder titles,
/// descriptions and tags mirror `<project>/<folder>/.ok/frontmatter.yml`;
/// `indexHeading` is the `###` section of the project's `index.md`.
public enum OKKnowledgeType: String, Codable, CaseIterable, Sendable {
    case decisao
    case regraDeNegocio = "regra-de-negocio"
    case arquitetura
    case tutorial
    case gotcha
    case termo
    case snippet

    public init?(folder: String) {
        guard let type = Self.allCases.first(where: { $0.folder == folder }) else { return nil }
        self = type
    }

    public var folder: String {
        switch self {
        case .decisao: "decisoes"
        case .regraDeNegocio: "regras-de-negocio"
        case .arquitetura: "arquitetura"
        case .tutorial: "tutoriais"
        case .gotcha: "gotchas"
        case .termo: "glossario"
        case .snippet: "snippets"
        }
    }

    /// `.ok/templates/<templateName>.md`.
    public var templateName: String { rawValue }

    public var indexHeading: String {
        switch self {
        case .decisao: "Decisões (ADR)"
        case .regraDeNegocio: "Regras de negócio"
        case .arquitetura: "Arquitetura"
        case .tutorial: "Tutoriais"
        case .gotcha: "Gotchas"
        case .termo: "Glossário"
        case .snippet: "Snippets"
        }
    }

    public func folderTitle(project: String) -> String {
        "\(indexHeading) — \(project)"
    }

    public func folderDescription(project: String) -> String {
        switch self {
        case .decisao: "Registro de decisões arquiteturais do \(project)."
        case .regraDeNegocio: "Regras de domínio, invariantes e políticas do \(project)."
        case .arquitetura: "Componentes, fluxos e integrações do \(project)."
        case .tutorial: "How-tos, runbooks e setup do \(project)."
        case .gotcha: "Armadilhas e bugs recorrentes do \(project)."
        case .termo: "Termos do domínio do \(project)."
        case .snippet: "Código reutilizável e padrões do \(project)."
        }
    }

    public func folderTags(project: String) -> [String] {
        [rawValue, project]
    }
}
