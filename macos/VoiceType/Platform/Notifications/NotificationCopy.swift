import Foundation

/// All pt-BR copy emitted by the `Notifier`. Centralized so error paths
/// across the app reference one constant instead of inlining strings.
/// Source of pre-existing strings: `src/shared/messages.ts`.
enum NotificationCopy {
    // Groq key
    static let recordingCapTitle = "Limite de 5 min atingido"
    static let recordingCapBody  = "Gravação encerrada; processando o que foi gravado."

    static let missingGroqKeyTitle = "Chave Groq ausente"
    static let missingGroqKeyBody  = "Abra Settings e cole a chave da Groq antes de gravar."

    // Mic permission
    static let micDeniedTitle = "Microfone negado"
    static let micDeniedBody  = "Permita acesso ao microfone em System Settings → Privacy & Security → Microphone."

    // Accessibility permission
    static let accessibilityMissingTitle = "Acessibilidade necessária"
    static let accessibilityMissingBody  = "Habilite VoiceType em System Settings → Privacy & Security → Accessibility para usar push-to-talk e colar."

    // Secure Event Input (password fields etc.) blinds the CGEventTap
    static let secureInputTitle = "Atalho bloqueado"
    static func secureInputBody(ownerApp: String?) -> String {
        let who = ownerApp.map { "\($0) ativou" } ?? "Um app ativou"
        return "\(who) a entrada segura (campo de senha). O atalho do VoiceType não funciona até ela ser desligada."
    }

    // Transcription / pipeline
    static let transcriptionErrorTitle = "Falha na transcrição"
    static func transcriptionErrorBody(_ detail: String) -> String {
        "Groq retornou erro: \(detail)"
    }

    static let localModelNotReadyTitle = "Modelo local não está pronto"
    static let localModelNotReadyBody  = "Aguarde o download e a preparação terminarem em Ajustes → Transcrição local."

    static let pipelineCancelledTitle = "Gravação cancelada"
    static let pipelineCancelledBody  = "A captura anterior foi descartada porque você iniciou uma nova."

    // LLM pass degraded to the raw transcription because Groq rejected the
    // request permanently (decommissioned model, invalid key). Offline never
    // lands here — that fallback is silent by design. See G-025.
    static let refineDegradedTitle = "Colado sem refino"
    static let translateDegradedTitle = "Colado sem tradução"
    static func degradedBody(_ detail: String) -> String {
        "\(detail) O texto foi colado como transcrito. Confira a chave e o modelo em Settings."
    }

    // Paste
    static let pasteFailedTitle = "Não foi possível colar"
    static let pasteFailedBody  = "O app em foco recusou Cmd+V. Copie do histórico se precisar."

    // Voice note (#79)
    static func voiceNoteSavedTitle(_ title: String) -> String { "Ideia salva: \(title)" }
    static let voiceNoteUntitledTitle = "Ideia salva sem título (Claude indisponível)"
    static let voiceNoteFailedTitle = "Não foi possível salvar a ideia"
    static func voiceNoteFailedBody(_ detail: String) -> String {
        "\(detail) O texto foi copiado para a área de transferência."
    }

    // Auto-start
    static let autoStartFailedTitle = "Falha no auto-start"
    static func autoStartFailedBody(_ detail: String) -> String {
        "Não foi possível registrar VoiceType para iniciar com o sistema: \(detail)"
    }

    static let autoStartRequiresApprovalTitle = "Aprovação pendente"
    static let autoStartRequiresApprovalBody  = "Abra Configurações do Sistema → General → Login Items e ative VoiceType."

    // Audio capture
    static let captureStartFailedTitle = "Falha ao iniciar captura"
    static func captureStartFailedBody(_ detail: String) -> String {
        "O microfone recusou iniciar: \(detail)"
    }

    static let captureStopFailedTitle = "Falha ao parar captura"
    static func captureStopFailedBody(_ detail: String) -> String {
        "Não foi possível finalizar a gravação: \(detail)"
    }

    static let silentAudioTitle = "Áudio silencioso"
    static let silentAudioBody  = "Nenhum som captado. Verifique se o microfone certo está selecionado em Settings → Áudio e não está mudo."

    // Focus target
    static let noTargetTitle = "Sem app de destino"
    static let noTargetBody  = "Foque uma janela antes de iniciar a gravação."
}
