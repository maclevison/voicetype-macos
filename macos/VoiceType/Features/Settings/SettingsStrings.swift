import Core
import Foundation

/// pt-BR copy table for the Phase 6 Settings UI. Mirrors entries from
/// `src/shared/messages.ts` for the keys reused by the macOS native build,
/// plus the new strings introduced in Phase 6 (sidebar, refine style,
/// translate target, audio device picker, permission rows, About).
enum SettingsStrings {
    static let header = "Configurações"

    // Sidebar
    static let sidebarGeneral = "Geral"
    static let sidebarShortcuts = "Atalhos"
    static let sidebarAudio = "Áudio"
    static let sidebarVocabulary = "Vocabulário"
    static let sidebarAppearance = "Aparência"
    static let sidebarHistory = "Armazenamento"
    static let sidebarStartup = "Inicialização"
    static let sidebarAbout = "Sobre"

    // General
    static let apiKeyLabel = "Chave da Groq API"
    static let apiKeyPlaceholder = "gsk_..."
    static let apiKeyHelp = "A chave fica armazenada localmente."
    static let testButton = "Testar chave"
    static let testButtonLoading = "Testando..."
    static let testOk = "Válida"
    static func testInvalid(_ status: Int) -> String { "Inválida (status \(status))" }
    static let testNoResponse = "Sem resposta"
    static let languageLabel = "Idioma da fala"
    static let refineStyleLabel = "Estilo de refinamento"
    static let sidebarRefineStyle = "Estilo por app"
    static let cursorContextLabel = "Usar o texto em volta do cursor no refino"
    static let cursorContextHelp = "Lê até 500 caracteres antes/depois do cursor (nunca campos de senha) para acertar maiúscula e pontuação ao ditar no meio de uma frase. O texto lido é só referência e nunca é colado."
    static let categoryStylesHeader = "Estilo por categoria de app"
    static let categoryStylesHelp = "Apps conhecidos são agrupados por categoria. \"Usar global\" segue o estilo da aba Geral. Apps desconhecidos sempre usam o estilo global."
    static let styleUseGlobal = "Usar global"
    static let appOverridesHeader = "Estilo por app (tem prioridade)"
    static let appOverridesHelp = "Sobrescreve a categoria e o estilo global para um app específico."
    static let addAppOverride = "Adicionar app"
    static let addAppOverridePlaceholder = "Escolher app aberto…"
    static let removeAppOverride = "Remover"
    static func categoryLabel(_ category: AppCategory) -> String {
        switch category {
        case .email:    return "E-mail"
        case .chat:     return "Chat"
        case .ai:       return "Assistentes de IA"
        case .document: return "Documentos e notas"
        case .other:    return "Outros"
        }
    }
    static let terminalBypassSectionLabel = "Terminais: colar sem refino"
    static let terminalBypassHelp = "Nos terminais marcados, o texto é colado como transcrito (o dicionário continua valendo), para não estragar comandos. Desmarque para refinar normalmente naquele app."
    static let feedbackSectionLabel = "Feedback de gravação"
    static let soundFeedbackLabel = "Tocar som ao iniciar gravação"
    static let soundFeedbackHelp = "Som curto confirma que a gravação começou, útil quando o HUD não está visível."
    static let autoEnterLabel = "Enviar Enter após colar"
    static let autoEnterHelp = "Dispara Return automaticamente após o paste. Útil pra chats e agentes."

    // Shortcuts
    static let shortcutLabel = "Atalho global"
    static let shortcutHelp = "Um modificador (Cmd / Ctrl / Alt / Shift) + uma tecla, ou só modificadores: fn sozinho ou dois juntos (ex.: ⌃⌥). Usando fn/🌐, ajuste Ajustes do Sistema → Teclado → \"Pressionar 🌐 para\" → \"Não Fazer Nada\" (senão abre emojis/ditado)."
    static let handsFreeLabel = "Mãos livres (toque duplo)"
    static let handsFreeHelp = "Toque duas vezes no atalho para gravar sem segurar; toque de novo para colar, Esc cancela. Segurando o atalho, Espaço também trava a gravação."
    static let translateEnabledLabel = "Ativar atalho de tradução (PT → EN)"
    static let translateShortcutLabel = "Atalho de tradução"
    static let translateHelp = "Falando em PT, cola em inglês. Atalho independente do principal."
    static let translateShortcutConflict = "Atalho de tradução não pode ser igual ao atalho principal, nem um conter o outro."
    static let voiceNoteShortcutLabel = "Nota de voz"
    static let voiceNoteShortcutHelp = "Segure e fale uma ideia: vira nota na pasta de reuniões, com link na daily note."
    static let voiceNoteShortcutConflict = "Atalho da nota de voz não pode ser igual ao de ditado ou tradução, nem conter um deles (ex.: ⌃⇧ dentro de ⌃⇧N)."
    static let translateTargetLabel = "Idioma de tradução"
    static let shortcutRecorderRecord = "Gravar"
    static let shortcutRecorderCapturing = "Pressione teclas..."
    static let shortcutRecorderCancel = "Cancelar"

    // Appearance
    static let appearanceWaveformSectionLabel = "Visualização da onda"
    static let appearanceWaveformPresetLabel = "Paleta da waveform"
    static let appearanceWaveformPresetHelp = "A nova paleta aparece na próxima gravação."
    static let appearanceIndicatorStyleSectionLabel = "Indicador de gravação"
    static let appearanceIndicatorStyleLabel = "Estilo do indicador"
    static let appearanceIndicatorStyleHelp = "Automático usa o notch em MacBooks que o têm, e a barra flutuante nos demais."

    // Audio
    static let micDeviceLabel = "Microfone"
    static let micDeviceDefault = "Sistema padrão"
    static let micDevicePermissionHint = "Permita acesso ao microfone para listar os dispositivos."
    static let micDevicePermissionButton = "Solicitar acesso"
    static let micDeviceContinuityTag = "iPhone (Continuity)"
    static let micDevicePreviewSectionLabel = "Pré-visualização"
    static let micDevicePreviewLevelLabel = "Nível"
    static let micDeviceTestButton = "Testar microfone (5s)"
    static let micDeviceTestingHint = "Capturando nível..."
    static let continuitySectionLabel = "Fallback automático"
    static let continuityToggleLabel = "Usar iPhone via Continuity se o mic padrão falhar"
    static let continuityToggleHelp = "Quando nenhum mic está disponível (ex: notebook em clamshell sem mic externo), tenta usar o iPhone via Continuity Capture automaticamente."

    // Vocabulary
    static let vocabularyHeader = "Termos personalizados"
    static let vocabularyHelp = "Lista termos (nomes, jargão, código) que devem aparecer nas transcrições. Um por linha ou separados por vírgula. Limite de ~900 caracteres."
    static let vocabularyPlaceholder = "Ex.: Macsilva, FluidAudio, Codex"
    static func vocabularyCount(used: Int, max: Int) -> String { "(\(used) / ~\(max) chars)" }
    static let vocabularyMaxChars = 900
    static let learnHeader = "Aprender com minhas edições"
    static let learnLabel = "Sugerir termos a partir das minhas correções"
    static let learnHelp = "Depois de colar, relê uma única vez (~20 s depois) só o trecho colado — nunca o resto do campo nem campos de senha — e compara palavra a palavra. Correções que parecem erro de transcrição viram sugestões abaixo; nada entra no dicionário sem sua aprovação."
    static let learnEmpty = "Nenhuma sugestão pendente."
    static let learnApprove = "Aprovar"
    static let learnReject = "Rejeitar"
    static let learnDelete = "Apagar"

    // History
    static let keepHistoryLabel = "Manter histórico"
    static let historyRetentionLabel = "Quantidade máxima de entradas"
    static let openHistoryButton = "Ver histórico"

    // Meetings
    static let sidebarMeetings = "Reuniões"
    static let meetingNotesHeader = "Notas"
    static let meetingNotesFolderLabel = "Pasta das notas"
    static let meetingChooseFolder = "Escolher…"
    static let meetingShowInFinder = "Mostrar no Finder"
    static let meetingVaultKindLabel = "Vault padrão"
    static let meetingVaultKindOptions: [(id: String, label: String)] = [
        ("obsidian", "Obsidian"),
        ("openknowledge", "OpenKnowledge"),
    ]
    static let meetingOKVaultLabel = "Raiz do projeto OpenKnowledge"
    static let meetingVaultNotOK = "Não é um projeto OpenKnowledge (falta a pasta .ok/)."
    static let meetingVaultUnset = "Escolha a raiz de um projeto OpenKnowledge (a pasta com .ok/)."
    static let meetingOKHelp = "Reuniões viram pendências de aprovação no menu; notas de voz vão para _inbox/."
    static let meetingCLIPathLabel = "Caminho do Claude CLI (vazio = detectar)"
    static let meetingCLINotFound = "não encontrado"
    static let meetingCalendarHeader = "Calendário"
    static let meetingCalendarLabel = "Acesso ao Calendário"
    static let meetingCalendarAllow = "Permitir acesso"
    static let meetingCalendarHelp = "Lê o evento do Calendário do Mac que coincide com a gravação: o título orienta o da nota e os convidados entram nela como [[links]]. Contas Exchange/Outlook e Google adicionadas em Ajustes → Contas de Internet também contam. Nunca inicia nem para gravações."
    static let meetingCaptureHeader = "Gravação"
    static let meetingDetectionLabel = "Ao detectar reunião"
    static let meetingDetectionOptions: [(id: String, label: String)] = [
        ("ask", "Perguntar"),
        ("auto", "Gravar automaticamente"),
        ("off", "Desligado"),
    ]
    static let meetingRetentionLabel = "Apagar áudio após"
    static func meetingRetentionValue(_ days: Int) -> String {
        days == 0 ? "Nunca apagar" : days == 1 ? "1 dia" : "\(days) dias"
    }
    static let meetingRetentionHelp = "Só apaga o áudio de reuniões que já têm nota. A nota e a transcrição nunca são apagadas."
    static let meetingOrgsHeader = "Organizações e clientes"
    static let meetingOrgName = "Organização"
    static let meetingClientName = "Cliente"
    static let meetingAliasesLabel = "Aliases (separados por vírgula)"
    static let meetingAliasesPrompt = "ex.: ACME, Acme Corp"
    static let meetingAddOrg = "Adicionar organização"
    static let meetingAddClient = "Adicionar cliente"
    static let meetingRemoveOrg = "Remover organização"
    static let meetingRemoveClient = "Remover cliente"
    static let meetingOrgsHelp = "Usado para classificar as notas nas pastas por organização. Alterações só são salvas quando não há erros."
    static let meetingFallbackMissing = "Sem a organização \"\(MeetingOrg.fallbackName)\", reuniões sem organização clara ficam sem org."

    // Startup
    static let startAtLoginLabel = "Iniciar com o sistema"
    static let loginItemRequiresApproval = "Aprovação pendente — abra Login Items e ative VoiceType."
    static let permissionsHeader = "Permissões"
    static let permissionMic = "Microfone"
    static let permissionAccessibility = "Acessibilidade"
    static let permissionNotifications = "Notificações"
    static let permissionGranted = "Concedida"
    static let permissionDenied = "Negada"
    static let permissionUndetermined = "Não solicitada"
    static let openSystemSettings = "Abrir Configurações"

    // About
    static let aboutVersion = "Versão"
    static let aboutBuild = "Build"
    static let aboutLicense = "Licença"
    static let aboutGitHub = "GitHub"

    // Local Transcription
    static let sidebarLocalTranscription = "Transcrição local"
    static let localTranscriptionHeader = "Transcrição local"
    static let localTranscriptionEngineLabel = "Motor de transcrição"
    static let engineAuto = "Automático (local, cai pra Groq)"
    static let engineLocal = "Sempre local"
    static let engineGroq = "Sempre Groq"
    static func modelStatusDownloading(_ pct: Int) -> String { "Baixando modelo… \(pct)%" }
    static let modelStatusReady = "Modelo pronto (on-device)"
    static let modelStatusNotReady = "Modelo não carregado — usando Groq"
    static func modelStatusFailed(_ msg: String) -> String { "Falha ao carregar modelo: \(msg)" }
    static let localTranscriptionRefineNote = "Este seletor controla apenas a transcrição (áudio → texto). O refino e a tradução ainda usam o Groq (precisam de internet). Sem conexão, o texto transcrito é colado sem refino, em vez de se perder."

    // Local Refinement
    static let sidebarLocalRefinement = "Refino on-device"
    static let localRefinementHeader = "Refino on-device"
    static let localRefinementEngineLabel = "Motor de refino"
    static let localTranslateEngineLabel = "Motor de tradução"
    static let localRefinementStatusAvailable = "Apple Intelligence disponível"
    static let localRefinementStatusRequires26 = "Requer macOS 26 — usando Groq"
    static let localRefinementIndependenceNote = "Transcrição, refino e tradução usam engines independentes. Alterar um não afeta os outros."

    // Picker options
    static let languageOptions: [(id: String, label: String)] = [
        ("pt-BR", "Português (Brasil)"),
        ("en-US", "Inglês (EUA)"),
        ("es-ES", "Espanhol"),
    ]
    static let translateTargetOptions: [(id: String, label: String)] = [
        ("en-US", "Inglês (EUA)"),
        ("en-GB", "Inglês (UK)"),
        ("es-ES", "Espanhol"),
    ]
    static let refineStyleOptions: [(id: String, label: String)] = [
        ("natural", "Natural"),
        ("concise", "Conciso"),
        ("formal", "Formal"),
    ]
}
