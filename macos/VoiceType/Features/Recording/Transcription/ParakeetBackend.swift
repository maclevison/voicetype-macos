import Foundation
import FluidAudio

/// A loaded Parakeet Ultra model (FluidAudio). Takes no vocabulary.
final class ParakeetBackend: LocalSpeechBackend, @unchecked Sendable {
    /// The model rejects input shorter than one second at 16 kHz.
    private static let minimumSamples = 16_000

    private let manager: AsrManager

    init(manager: AsrManager) {
        self.manager = manager
    }

    func transcribe(samples: [Float], lang: String, vocabulary: String?) async throws -> String {
        var audio = samples
        if audio.count < Self.minimumSamples {
            audio += [Float](repeating: 0, count: Self.minimumSamples - audio.count)
        }
        // Fresh state per call: dictations are independent utterances.
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(audio, decoderState: &state, language: Language(rawValue: "pt"))
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
