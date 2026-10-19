import Foundation
import Core
import CoreML
import WhisperKit
import os

/// A loaded WhisperKit model.
///
/// **Concurrency invariant (não-Sendable off-actor, FU-N10):**
/// `WhisperKit` não é `Sendable`, mas o acesso é seguro aqui por duas razões combinadas:
///
/// 1. **Kit imutável pós-ready** — o backend só é criado depois que `loadModels()` e
///    `prewarmModels()` terminaram, ponto a partir do qual o objeto não é mais mutado.
///    Não há escrita concorrente enquanto `transcribe` está rodando.
///
/// 2. **Pipeline serializado** — cada nova gravação cancela a `Task` anterior antes de criar
///    uma nova (veja `RecordingOrchestrator`). Há no máximo um consumidor ativo de `kit`
///    por vez; não há corrida de leitura/escrita entre duas chamadas simultâneas.
///
/// **Revisão necessária na migração Swift 6 / strict concurrency:**
/// Ao habilitar `-strict-concurrency=complete` no App target, rever se a invariância
/// acima ainda vale antes de manter o `@unchecked Sendable`, ou isolar o backend num ator.
final class WhisperKitBackend: LocalSpeechBackend, @unchecked Sendable {
    private let kit: WhisperKit
    private static let logger = Logger(subsystem: "dev.voicetype.app", category: "LocalTranscriber")

    init(kit: WhisperKit) {
        self.kit = kit
    }

    func transcribe(samples: [Float], lang: String, vocabulary: String?) async throws -> String {
        let promptTokens = Self.promptTokens(tokenizer: kit.tokenizer, vocabulary: vocabulary)
        let options = DecodingOptions(
            verbose: false, task: .transcribe, language: lang,
            temperature: 0.0, temperatureFallbackCount: 0,
            usePrefillPrompt: true, detectLanguage: false,
            skipSpecialTokens: true, withoutTimestamps: false,
            promptTokens: promptTokens, chunkingStrategy: .vad
        )
        let audioSeconds = Double(samples.count) / 16_000.0
        let clock = ContinuousClock()
        let start = clock.now
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        let elapsed = start.duration(to: clock.now)
        let text = results.map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Self.logger.info("local transcription done: \(elapsed.description, privacy: .public) for \(audioSeconds, format: .fixed(precision: 1), privacy: .public)s audio, \(text.count, privacy: .public) chars")
        return text
    }

    private static func promptTokens(tokenizer: WhisperTokenizer?, vocabulary: String?) -> [Int]? {
        guard let tokenizer, let raw = vocabulary else { return nil }
        let keywords = VocabularyTerms.parse(raw)
        guard !keywords.isEmpty else { return nil }
        let specialBegin = tokenizer.specialTokens.specialTokenBegin
        let tokens = tokenizer.encode(text: keywords.joined(separator: ", ")).filter { $0 < specialBegin }
        return tokens.isEmpty ? nil : tokens
    }
}

/// `WhisperKit` whose transcribe tasks decode through `PromptSafeTextDecoder` (G-036).
final class PromptSafeWhisperKit: WhisperKit, @unchecked Sendable {
    override func setupTranscribeTask(
        currentTimings: TranscriptionTimings,
        progress: Progress,
        audioProcessor: any AudioProcessing,
        audioEncoder: any AudioEncoding,
        featureExtractor: any FeatureExtracting,
        segmentSeeker: any SegmentSeeking,
        textDecoder: any TextDecoding,
        tokenizer: any WhisperTokenizer
    ) -> TranscribeTask {
        super.setupTranscribeTask(
            currentTimings: currentTimings,
            progress: progress,
            audioProcessor: audioProcessor,
            audioEncoder: audioEncoder,
            featureExtractor: featureExtractor,
            segmentSeeker: segmentSeeker,
            textDecoder: PromptSafeTextDecoder(base: textDecoder),
            tokenizer: tokenizer
        )
    }
}

/// Delegates everything to WhisperKit's decoder, but when the prompt carries
/// vocabulary (`<|startofprev|> … <|startoftranscript|> <|pt|> …`) it decodes
/// with a `ForcedPrefixSampler`.
///
/// WhisperKit 1.0.0's `decodeText` ends the segment as soon as the sampler
/// predicts EOT, even at prompt positions whose next token is forced anyway.
/// The large-v3 models predict EOT right after the forced `<|pt|>`, so the loop
/// stops before the first real token and the text comes back empty (G-036).
final class PromptSafeTextDecoder: TextDecoding {
    private var base: any TextDecoding

    init(base: any TextDecoding) {
        self.base = base
    }

    var tokenizer: WhisperTokenizer? {
        get { base.tokenizer }
        set { base.tokenizer = newValue }
    }
    var isModelMultilingual: Bool {
        get { base.isModelMultilingual }
        set { base.isModelMultilingual = newValue }
    }
    var logitsFilters: [any LogitsFiltering]? {
        get { base.logitsFilters }
        set { base.logitsFilters = newValue }
    }
    var supportsWordTimestamps: Bool { base.supportsWordTimestamps }
    var logitsSize: Int? { base.logitsSize }
    var kvCacheEmbedDim: Int? { base.kvCacheEmbedDim }
    var kvCacheMaxSequenceLength: Int? { base.kvCacheMaxSequenceLength }
    var windowSize: Int? { base.windowSize }
    var embedSize: Int? { base.embedSize }

    func predictLogits(_ inputs: any TextDecoderInputType) async throws -> TextDecoderOutputType? {
        try await base.predictLogits(inputs)
    }

    func prepareDecoderInputs(withPrompt initialPrompt: [Int]) throws -> any DecodingInputsType {
        try base.prepareDecoderInputs(withPrompt: initialPrompt)
    }

    func prefillDecoderInputs(
        _ decoderInputs: any DecodingInputsType, withOptions options: DecodingOptions?
    ) async throws -> any DecodingInputsType {
        try await base.prefillDecoderInputs(decoderInputs, withOptions: options)
    }

    func decodeText(
        from encoderOutput: any AudioEncoderOutputType,
        using decoderInputs: any DecodingInputsType,
        sampler tokenSampler: TokenSampling,
        options decoderOptions: DecodingOptions,
        callback: TranscriptionCallback?
    ) async throws -> DecodingResult {
        var sampler = tokenSampler
        let prompt = decoderInputs.initialPrompt
        if let tokenizer, prompt.first == tokenizer.specialTokens.startOfPreviousToken {
            sampler = ForcedPrefixSampler(
                base: tokenSampler,
                firstIndex: decoderInputs.cacheLength[0].intValue,
                lastForcedIndex: prompt.count - 1
            )
        }
        return try await base.decodeText(
            from: encoderOutput, using: decoderInputs, sampler: sampler,
            options: decoderOptions, callback: callback
        )
    }

    func detectLanguage(
        from encoderOutput: any AudioEncoderOutputType,
        using decoderInputs: any DecodingInputsType,
        sampler tokenSampler: TokenSampling,
        options: DecodingOptions,
        temperature: FloatType
    ) async throws -> DecodingResult {
        try await base.detectLanguage(
            from: encoderOutput, using: decoderInputs, sampler: tokenSampler,
            options: options, temperature: temperature
        )
    }
}

/// Wraps the decode loop's sampler for one `decodeText` call. `decodeText` calls
/// `update` once per position, starting at `firstIndex`; positions before
/// `lastForcedIndex` have their next token forced from the prompt, so an EOT
/// predicted there must not end the segment. Its log-prob is zeroed too, so
/// `firstTokenLogProbThreshold` does not judge a token that is never used.
final class ForcedPrefixSampler: TokenSampling {
    private let base: TokenSampling
    private var tokenIndex: Int
    private let lastForcedIndex: Int

    init(base: TokenSampling, firstIndex: Int, lastForcedIndex: Int) {
        self.base = base
        self.tokenIndex = firstIndex
        self.lastForcedIndex = lastForcedIndex
    }

    func update(tokens: [Int], logits: MLMultiArray, logProbs: [Float]) async -> SamplingResult {
        var result = await base.update(tokens: tokens, logits: logits, logProbs: logProbs)
        if tokenIndex < lastForcedIndex {
            result.completed = false
            if !result.logProbs.isEmpty { result.logProbs[result.logProbs.count - 1] = 0 }
        }
        tokenIndex += 1
        return result
    }

    func finalize(tokens: [Int], logProbs: [Float]) -> SamplingResult {
        base.finalize(tokens: tokens, logProbs: logProbs)
    }
}
