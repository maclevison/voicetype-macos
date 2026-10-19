import Core
import Foundation

enum ErrorPresenter {
    static func describe(_ error: PipelineError) -> String {
        switch error {
        case .missingApiKey: return "Configure a chave Groq nas Settings."
        case .missingTranslateTarget: return "Idioma de destino não configurado."
        case .emptyTranscription: return "Nada transcrito. Tente falar de novo."
        case .http(let status, _) where status == 401: return "Chave Groq inválida."
        case .http(let status, _) where status == 403: return GroqError.networkBlockedDescription
        case .http(let status, _) where status == 429: return "Rate limit Groq atingido."
        case .http(let status, _): return "Erro Groq (\(status))."
        case .network: return "Sem internet."
        case .cancelled: return "Cancelado."
        case .timeout: return "Tempo esgotado, tente de novo."
        case .unknown(let message): return message
        }
    }

    static func describe(_ error: PasterError) -> String {
        switch error {
        case .targetAppNotRunning: return "O app de destino fechou antes do paste."
        case .targetActivationFailed: return "Não foi possível ativar o app de destino."
        case .eventInjectionFailed: return "Falha ao enviar Cmd+V. Verifique Acessibilidade."
        case .accessibilityMissing: return "Permita Acessibilidade ao VoiceType para colar automaticamente."
        case .noEditableField: return "Nenhum campo de texto em foco. O texto ficou na área de transferência — cole com Cmd+V."
        case .clipboardWriteFailed: return "Não foi possível escrever na área de transferência."
        case .pasteNotConsumed: return "O app em foco não recebeu o texto. Ele ficou na área de transferência — cole com Cmd+V."
        case .focusMoved: return "O campo de destino mudou. O texto ficou na área de transferência — cole com Cmd+V."
        }
    }
}
