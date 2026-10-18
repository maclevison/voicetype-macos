import Core
import Foundation

/// pt-BR copy for the OpenKnowledge approvals: menu, discard alert, the
/// approval window and the notifications of a vault write the launch had to
/// finish or undo.
enum ApprovalStrings {
    static let windowTitle = "Aprovar reunião"
    static let noMeeting = "Nenhuma reunião selecionada."

    // Menu
    static func pendingMenu(_ count: Int) -> String {
        count == 1 ? "1 reunião aguardando aprovação" : "\(count) reuniões aguardando aprovação"
    }

    static func item(_ meeting: PendingMeeting) -> String {
        "\(meeting.title) — \(meeting.startedAt.formatted(itemDate))"
    }

    static let review = "Revisar…"
    static let discard = "Descartar…"

    private static let itemDate = Date.VerbatimFormatStyle(
        format: "\(day: .twoDigits)/\(month: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
        timeZone: .current, calendar: Calendar(identifier: .gregorian)
    )

    // Discard
    static func discardTitle(_ title: String) -> String { "Descartar “\(title)”?" }
    static let discardBody = "Nada desta reunião será gravado no vault. O áudio e a transcrição continuam no Mac."
    static let discardConfirm = "Descartar"
    static let cancel = "Cancelar"
    static func discardBusyTitle(_ title: String) -> String { "“\(title)” não pode ser descartada agora" }
    static let discardBusyBody = "Uma gravação desta reunião no vault está em andamento ou foi interrompida. O VoiceType conclui ou desfaz essa gravação no próximo início ou ao abrir a reunião."

    // Recovery notifications
    static let partialTitle = "Gravação no vault concluída em parte"
    static func partialBody(count: Int, title: String, preserved: [String]) -> String {
        let changed = count == 1
            ? "1 item de “\(title)” mudou durante a gravação e voltou para revisão."
            : "\(count) itens de “\(title)” mudaram durante a gravação e voltaram para revisão."
        let kept = preserved.isEmpty ? "" : " Versões externas guardadas em \(preserved.joined(separator: ", "))."
        return changed + " O registro e a transcrição já estão no vault." + kept
    }

    /// The meeting is in the vault, but another app wrote a doc's old
    /// version while it was taken out: that edit is only in its copy.
    static let divergedTitle = "Edição externa guardada à parte"
    static func divergedBody(title: String, _ divergences: [OKDivergence]) -> String {
        let paths = divergences.map(\.path).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let copies = divergences.compactMap(\.preservedCopy)
        let edited = paths.count == 1 ? paths[0] : "\(paths.count) arquivos (\(paths.joined(separator: ", ")))"
        let kept = copies.count == 1 ? "A edição foi guardada em" : "As edições foram guardadas em"
        return "“\(title)” foi gravada no vault, mas outro app editou \(edited) durante a gravação e o vault ficou com a versão do VoiceType. \(kept) \(copies.joined(separator: ", "))."
    }

    static let incompleteTitle = "Gravação no vault incompleta"
    static func incompleteBody(_ paths: [String]) -> String {
        "Faltou gravar \(paths.joined(separator: ", ")). O VoiceType tenta de novo no próximo início ou ao abrir a reunião."
    }

    static let rolledBackTitle = "Gravação no vault desfeita"
    static func rolledBackBody(count: Int, title: String) -> String {
        let changed = count == 1 ? "1 doc mudou" : "\(count) docs mudaram"
        return "\(changed) durante a gravação. Revise de novo a reunião “\(title)”."
    }

    static let interruptedTitle = "Gravação no vault interrompida"
    static func divergencesBody(paths: [String], copies: [String]) -> String {
        let edited = paths.count == 1 ? "1 arquivo foi editado" : "\(paths.count) arquivos foram editados"
        let undone = paths.count == 1 ? "não foi desfeito" : "não foram desfeitos"
        return "\(edited) durante a gravação e \(undone): \(paths.joined(separator: ", ")). Cópias em \(copies.joined(separator: ", "))."
    }

    static func vaultUnavailableBody(_ root: String) -> String {
        "O vault \(root) não está acessível. Nada foi alterado; o VoiceType tenta de novo no próximo início."
    }

    static func recoveryFailedBody(_ error: String) -> String {
        "\(error) O VoiceType tenta de novo no próximo início ou ao abrir a reunião."
    }

    // Window
    static func stepCounter(_ k: Int, of n: Int) -> String { "Passo \(k) de \(n)" }
    static let projectStep = "Projeto"
    static let searchProjects = "Buscar projeto"
    static let suggested = "sugerido"
    static let newProject = "＋ Novo projeto…"
    static func projectLocked(_ project: String) -> String { "Projeto fixado na primeira aprovação: \(project)" }
    static let recordLabel = "Registro da reunião"
    static func newItem(_ type: OKKnowledgeType) -> String { "novo · \(typeName(type))" }
    static func updateItem(_ type: OKKnowledgeType) -> String { "atualização · \(typeName(type))" }
    static let conflictItem = "conflito · já mudou no vault"
    static let preview = "Preview"
    static let editor = "Editor"
    static let undoEdits = "Desfazer edições"
    static let back = "Voltar"
    static let skip = "Pular"
    static let approve = "Aprovar"
    static let commit = "Gravar no vault"
    static let retryDistillation = "Tentar destilar de novo"
    static func summaryFailure(_ error: String) -> String { "Reunião sem resumo: \(error). Só o registro e a transcrição vão para o vault." }
    static func distillationError(_ error: String) -> String { "Sem conhecimento destilado: \(error). Dá para gravar só o registro e a transcrição." }

    static func typeName(_ type: OKKnowledgeType) -> String {
        switch type {
        case .decisao: "decisão"
        case .regraDeNegocio: "regra de negócio"
        case .arquitetura: "arquitetura"
        case .tutorial: "tutorial"
        case .gotcha: "gotcha"
        case .termo: "termo"
        case .snippet: "snippet"
        }
    }

    // Window progress and banners
    static func distilling(_ project: String) -> String { "Destilando contra \(project)…" }
    static func preparing(_ root: String) -> String { "Preparando para \(root)…" }
    static let committing = "Gravando no vault…"
    static func vaultMismatch(prepared: String, current: String) -> String {
        "Esta reunião foi preparada para \(prepared). O vault atual é \(current)."
    }
    static let unknownVault = "um vault inválido"
    static func prepareAgain(_ current: String) -> String { "Preparar de novo para \(current)" }
    static let journalPending = "Uma gravação desta reunião no vault ficou incompleta. O VoiceType conclui ao reabrir esta reunião ou no próximo início."
    static let reprocessed = "Esta reunião foi reprocessada. A revisão recomeçou com a proposta nova."
    static let gone = "Esta pendência não existe mais."
    static func distillFailed(_ project: String, _ error: String) -> String {
        "Não deu para destilar contra \(project) (\(error)). Dá para gravar só o registro e a transcrição, ou tentar de novo."
    }
    static let redistilled = "O vault mudou desde a proposta (ou ela tem mais de 24 h). A destilação foi refeita; revise os itens marcados."
    static func redistillFailed(_ error: String) -> String {
        "Não deu para refazer a destilação (\(error)). Pule os itens para gravar só o registro e a transcrição, ou tente de novo."
    }
    static func relocated(from old: String, to new: String) -> String {
        "Outra reunião já usa \(old). Esta passa a ser \(new); revise os passos marcados."
    }
    static let changedDuringCommit = "O vault mudou durante a gravação. Tente gravar de novo."
    static func conflicts(_ count: Int, preserved: [String]) -> String {
        let changed = count == 1 ? "1 item mudou" : "\(count) itens mudaram"
        return "\(changed) no vault desde a proposta. Revise de novo." + kept(preserved)
    }
    static func partial(_ count: Int, preserved: [String]) -> String {
        let changed = count == 1 ? "1 item mudou" : "\(count) itens mudaram"
        return "A reunião foi gravada, mas \(changed) no vault durante a gravação. Revise só esses itens." + kept(preserved)
    }
    static func incomplete(_ paths: [String]) -> String {
        "A gravação ficou incompleta (\(paths.joined(separator: ", "))). O VoiceType conclui ao reabrir esta reunião ou no próximo início."
    }
    static func finalizeFailed(_ error: String) -> String {
        "A reunião foi gravada no vault, mas o VoiceType não conseguiu concluir o estado local (\(error)). Reinicie o VoiceType para concluir."
    }
    static let committedTitle = "Reunião gravada no vault"

    private static func kept(_ preserved: [String]) -> String {
        preserved.isEmpty ? "" : " Versões externas guardadas em \(preserved.joined(separator: ", "))."
    }

    // New project sheet
    static let newProjectTitle = "Novo projeto"
    static let slugField = "Slug (kebab-case, sem acento)"
    static let descriptionField = "Descrição curta"
    static let invalidSlug = "Use letras minúsculas, números e hífens, sem acento (ex.: billing-api)."
    static let slugTaken = "Já existe um projeto com esse slug."
    static let create = "Criar"
    static func projectError(_ error: OKApprovalSession.ProjectError) -> String {
        switch error {
        case .invalidSlug: invalidSlug
        case .alreadyExists: slugTaken
        case .emptyDescription: "Informe a descrição do projeto."
        case .projectLocked: "O projeto desta reunião já foi fixado na primeira aprovação."
        }
    }
}
