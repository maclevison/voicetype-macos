import XCTest
import Core
@testable import VoiceType

final class ErrorPresenterTests: XCTestCase {

    // MARK: - PipelineError

    func test_pipelineError_missingApiKey() {
        XCTAssertEqual(
            ErrorPresenter.describe(PipelineError.missingApiKey),
            "Configure a chave Groq nas Settings."
        )
    }

    func test_pipelineError_missingTranslateTarget() {
        XCTAssertEqual(
            ErrorPresenter.describe(PipelineError.missingTranslateTarget),
            "Idioma de destino não configurado."
        )
    }

    func test_pipelineError_emptyTranscription() {
        XCTAssertEqual(
            ErrorPresenter.describe(PipelineError.emptyTranscription),
            "Nada transcrito. Tente falar de novo."
        )
    }

    func test_pipelineError_http401() {
        XCTAssertEqual(
            ErrorPresenter.describe(PipelineError.http(status: 401, message: "")),
            "Chave Groq inválida."
        )
    }

    func test_pipelineError_http429() {
        XCTAssertEqual(
            ErrorPresenter.describe(PipelineError.http(status: 429, message: "")),
            "Rate limit Groq atingido."
        )
    }

    func test_pipelineError_httpOther() {
        XCTAssertEqual(
            ErrorPresenter.describe(PipelineError.http(status: 500, message: "")),
            "Erro Groq (500)."
        )
    }

    func test_pipelineError_network() {
        XCTAssertEqual(
            ErrorPresenter.describe(PipelineError.network(message: "not connected")),
            "Sem internet."
        )
    }

    func test_pipelineError_cancelled() {
        XCTAssertEqual(
            ErrorPresenter.describe(PipelineError.cancelled),
            "Cancelado."
        )
    }

    func test_pipelineError_timeout() {
        XCTAssertEqual(
            ErrorPresenter.describe(PipelineError.timeout),
            "Tempo esgotado, tente de novo."
        )
    }

    func test_pipelineError_unknown() {
        XCTAssertEqual(
            ErrorPresenter.describe(PipelineError.unknown(message: "boom")),
            "boom"
        )
    }

    // MARK: - PasterError

    func test_pasterError_targetAppNotRunning() {
        XCTAssertEqual(
            ErrorPresenter.describe(PasterError.targetAppNotRunning),
            "O app de destino fechou antes do paste."
        )
    }

    func test_pasterError_targetActivationFailed() {
        XCTAssertEqual(
            ErrorPresenter.describe(PasterError.targetActivationFailed),
            "Não foi possível ativar o app de destino."
        )
    }

    func test_pasterError_eventInjectionFailed() {
        XCTAssertEqual(
            ErrorPresenter.describe(PasterError.eventInjectionFailed),
            "Falha ao enviar Cmd+V. Verifique Acessibilidade."
        )
    }

    func test_pasterError_accessibilityMissing() {
        XCTAssertEqual(
            ErrorPresenter.describe(PasterError.accessibilityMissing),
            "Permita Acessibilidade ao VoiceType para colar automaticamente."
        )
    }

    func test_pasterError_noEditableField() {
        XCTAssertEqual(
            ErrorPresenter.describe(PasterError.noEditableField),
            "Nenhum campo de texto em foco. O texto ficou na área de transferência — cole com Cmd+V."
        )
    }

    func test_pasterError_clipboardWriteFailed() {
        XCTAssertEqual(
            ErrorPresenter.describe(PasterError.clipboardWriteFailed),
            "Não foi possível escrever na área de transferência."
        )
    }

    func test_pasterError_pasteNotConsumed() {
        XCTAssertEqual(
            ErrorPresenter.describe(PasterError.pasteNotConsumed),
            "O app em foco não recebeu o texto. Ele ficou na área de transferência — cole com Cmd+V."
        )
    }

    func test_pasterError_focusMoved() {
        XCTAssertEqual(
            ErrorPresenter.describe(PasterError.focusMoved),
            "O campo de destino mudou. O texto ficou na área de transferência — cole com Cmd+V."
        )
    }
}
