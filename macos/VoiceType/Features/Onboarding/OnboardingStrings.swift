import Core
import Foundation

/// pt-BR copy for the onboarding window and its menu item. Shortcuts arrive
/// already pretty-printed from the real config.
enum OnboardingStrings {
    static let windowTitle = "Aprender a usar o VoiceType"
    static let menuItem = "Aprender a usar o VoiceType…"

    // Navigation
    static let back = "Anterior"
    static let next = "Próximo"
    static let finish = "Concluir"
    static func progress(_ position: Int, _ total: Int) -> String { "Passo \(position) de \(total)" }

    static let practiceDone = "Feito!"

    static func title(_ step: OnboardingStep) -> String {
        switch step {
        case .prepare:     return "Antes de começar"
        case .dictation:   return "Ditado"
        case .handsFree:   return "Mãos livres"
        case .translation: return "Tradução"
        case .voiceNote:   return "Nota de voz"
        case .history:     return "Histórico"
        case .meetings:    return "Reuniões"
        case .personalize: return "Personalize"
        }
    }

    // Antes de começar
    static let prepareIntro = "O VoiceType precisa de três permissões e de um modelo de transcrição. Este passo não bloqueia nada: dá para avançar agora, e cada prática avisa o que faltar."
    static let prepareMicHelp = "Para ouvir o que você dita."
    static let prepareAccessibilityHelp = "Para o atalho funcionar em qualquer app e para colar o texto."
    static let prepareNotificationsHelp = "Para avisar quando algo dá errado, por exemplo um ditado sem app em foco."
    static let localModelLabel = "Modelo de transcrição local"
    static let localModelUnknown = "Nenhum modelo escolhido"
    static let openLocalTranscription = "Abrir \(SettingsStrings.sidebarLocalTranscription)"

    // Práticas
    static let practiceFieldLabel = "Campo de prática"
    static let practiceFieldHelp = "O texto é colado aqui pelo mesmo caminho de qualquer app. Com o cursor fora do campo, nada é colado."
    static let practiceMissingHeader = "Antes de praticar:"

    static func dictationIntro(_ shortcut: String) -> String {
        "Segure \(shortcut), fale e solte. O texto refinado é colado no app em foco, onde estiver o cursor. Experimente aqui no campo abaixo."
    }

    static func handsFreeIntro(_ shortcut: String) -> String {
        "Toque duas vezes em \(shortcut) para gravar sem segurar e toque de novo para encerrar e colar. Esc cancela."
    }
    static func handsFreeUpgrade(_ shortcut: String, _ key: String) -> String {
        "Também dá para segurar \(shortcut) e apertar \(key) para travar a gravação."
    }
    static let handsFreeNote = "Segurar e soltar também cola, mas este passo só conta com a gravação travada."

    static func translationIntro(_ shortcut: String) -> String {
        "Segure \(shortcut), fale em português e solte: o texto é traduzido para o idioma configurado e colado no app em foco."
    }
    static let translationFellBack = "O texto chegou sem tradução: nenhum tradutor respondeu (sem Apple Intelligence, sem o idioma baixado para a Tradução da Apple e sem rede ou chave Groq). Fora do tutorial, o VoiceType cola o texto original nesse caso."

    static func blocker(_ blocker: OnboardingBlocker) -> String {
        switch blocker {
        case .accessibility:
            return "Falta a permissão de Acessibilidade: sem ela o atalho não funciona e nada é colado. Conceda em Ajustes do Sistema → Privacidade e Segurança → Acessibilidade."
        case .microphone:
            return "Falta a permissão do Microfone. Conceda em Ajustes do Sistema → Privacidade e Segurança → Microfone."
        case .groqKeyMissing:
            return "A transcrição está no Groq, mas não há chave. Cole a chave em Configurações → \(SettingsStrings.sidebarGeneral)."
        case .localModelNotReady:
            return "O modelo de transcrição local ainda não está pronto. Acompanhe em Configurações → \(SettingsStrings.sidebarLocalTranscription)."
        case .translateDisabled:
            return "A tradução está desligada. Ligue em Configurações → \(SettingsStrings.sidebarShortcuts)."
        case .translatorUnavailable:
            return "A tradução precisa do Apple Intelligence, dos idiomas baixados para a Tradução da Apple (Ajustes do Sistema → Geral → Idioma e Região → Idiomas de Tradução) ou de uma chave Groq. Escolha o motor em Configurações → \(SettingsStrings.sidebarLocalRefinement) ou cole a chave em Configurações → \(SettingsStrings.sidebarGeneral)."
        case .handsFreeDisabled:
            return "O modo mãos livres está desligado. Ligue em Configurações → \(SettingsStrings.sidebarShortcuts)."
        }
    }

    // Nota de voz
    static func voiceNoteIntro(_ shortcut: String) -> String {
        "Segure \(shortcut) e fale uma ideia. Ela não é colada: vira uma nota no vault."
    }
    static let voiceNoteOff = "A nota de voz está desligada (sem atalho). Defina um em Configurações → \(SettingsStrings.sidebarShortcuts)."
    static let voiceNoteObsidian = "No Obsidian, a ideia vira uma nota em Ideas/, com link na daily note do dia."
    static let voiceNoteOpenKnowledge = "No modo OpenKnowledge, a ideia vai para _inbox/ do projeto (_inbox/diario/ e _inbox/ideias/)."
    static let voiceNoteNoPractice = "Testar grava de verdade no vault, por isso este passo não tem prática."

    // Histórico
    // Only the practice keeps a refused paste in the Histórico (OnboardingPracticeDeliveryAdapter);
    // elsewhere RunPipelineUseCase records only after a successful paste.
    static let historyIntro = "Com o Histórico ligado (Configurações → \(SettingsStrings.sidebarHistory)), cada ditado colado fica guardado lá. Se uma colagem falhar, o texto não entra no Histórico: o aviso diz se ele ficou na área de transferência, e aí é colar com Cmd+V antes de copiar outra coisa. Só nesta prática o texto recusado também fica no Histórico."
    static let historyActions = "Em cada entrada: Recolar (cola de novo no app em foco), Copiar e Apagar."
    static let openHistory = "Abrir Histórico"

    // Reuniões
    static func meetingsDetection(_ mode: String) -> String {
        switch mode {
        case "auto":
            return "Quando um app de reunião (Teams, Zoom, Meet…) abre o microfone, a gravação começa sozinha e para quando a chamada termina."
        case "off":
            return "A detecção de reuniões está desligada: grave pelo menu."
        default:
            return "Quando um app de reunião (Teams, Zoom, Meet…) abre o microfone, aparece um cartão perguntando se deve gravar."
        }
    }
    static let meetingsMenu = "No menu: \"Gravar reunião\" (e \"Parar gravação\") e \"Reprocessar última reunião\". Enquanto grava, o ícone da barra de menu ganha um ponto vermelho."
    static let meetingsObsidian = "No fim, a transcrição e a nota com resumo vão para o vault do Obsidian."
    static let meetingsOpenKnowledge = "No modo OpenKnowledge, cada reunião vira uma pendência: o menu mostra as reuniões \"aguardando aprovação\", e nada vai para o vault antes da sua aprovação."
    static let openMeetings = "Abrir \(SettingsStrings.sidebarMeetings)"

    // Personalize
    static let personalizeIntro = "Ajuste o VoiceType ao seu jeito:"
    static let refineStyleLink = SettingsStrings.sidebarRefineStyle
    static let refineStyleHelp = "O tom do refino em cada app ou categoria."
    static let vocabularyLink = SettingsStrings.sidebarVocabulary
    static let vocabularyHelp = "Nomes e termos que a transcrição deve acertar."
    static let openKnowledgeLink = "Modo OpenKnowledge"
    static let openKnowledgeHelp = "Reuniões e notas de voz num projeto OpenKnowledge. As reuniões só vão para o vault depois da sua aprovação; as notas de voz são salvas direto em _inbox/, sem aprovação."
    static let personalizeReopen = "Reabra este tutorial quando quiser pelo menu: \(menuItem)"

    // Botões para Configurações
    static let openShortcuts = "Abrir \(SettingsStrings.sidebarShortcuts)"
    static let openGeneral = "Abrir \(SettingsStrings.sidebarGeneral)"
    static let openLocalRefinement = "Abrir \(SettingsStrings.sidebarLocalRefinement)"
}
