import Foundation

public enum LocalModelEngine: Sendable {
    case whisperKit, parakeet
}

public struct LocalModel: Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let summary: String
    public let sizeLabel: String
    public let engine: LocalModelEngine
    public let supportsVocabulary: Bool
    public let minimumMacOSMajor: Int
}

// The fixed list of on-device dictation models offered in Settings. IDs are the
// WhisperKit variant names (and "parakeet-ultra" for FluidAudio's ultra ASR) and
// double as folder names under the models directory.
public enum LocalModelCatalog {
    public static let defaultID = "openai_whisper-small"

    public static let all: [LocalModel] = [
        LocalModel(
            id: "openai_whisper-small",
            displayName: "Whisper Small",
            summary: "Leve. Erra mais em termos técnicos.",
            sizeLabel: "216 MB",
            engine: .whisperKit,
            supportsVocabulary: true,
            minimumMacOSMajor: 14
        ),
        // Takes the vocabulary only through PromptSafeTextDecoder (G-036).
        LocalModel(
            id: "openai_whisper-large-v3-v20240930_turbo_632MB",
            displayName: "Whisper Large v3 Turbo",
            summary: "Mais preciso em português e termos técnicos.",
            sizeLabel: "632 MB",
            engine: .whisperKit,
            supportsVocabulary: true,
            minimumMacOSMajor: 14
        ),
        // FluidAudio's Core ML path crashes in BNNS on macOS 14 (see MeetingDiarizer).
        LocalModel(
            id: "parakeet-ultra",
            displayName: "Parakeet Ultra",
            summary: "10× mais rápido. Não usa o vocabulário.",
            sizeLabel: "630 MB",
            engine: .parakeet,
            supportsVocabulary: false,
            minimumMacOSMajor: 15
        ),
    ]

    public static func model(id: String) -> LocalModel? {
        all.first { $0.id == id }
    }

    public static func available(macOSMajor: Int) -> [LocalModel] {
        all.filter { $0.minimumMacOSMajor <= macOSMajor }
    }
}
