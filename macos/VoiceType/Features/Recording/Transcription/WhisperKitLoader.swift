import Foundation
import WhisperKit

enum WhisperKitLoader {
    static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceType/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Downloads (first run) and loads a WhisperKit model into the app's
    /// models directory. Also used by the meeting pipeline for its own,
    /// short-lived large model. Cancellation is checked between phases, so a
    /// cancel during the download never starts the (uninterruptible) Core ML
    /// compile.
    static func loadKit(
        variant: String, downloadBase: URL = modelsDirectory,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> WhisperKit {
        let folder = try await download(variant: variant, downloadBase: downloadBase, onProgress: onProgress)
        try Task.checkCancellation()
        return try await loadKit(modelFolder: folder, tokenizerFolder: downloadBase)
    }

    /// Fetches whatever file of the model is missing and returns its folder,
    /// once every file is on disk.
    static func download(
        variant: String, downloadBase: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try await WhisperKit.download(variant: variant, downloadBase: downloadBase) { progress in
            onProgress(progress.fractionCompleted)
        }
    }

    /// Loads a model already on disk, without asking the repository for its
    /// file list (`WhisperKit.download` always does, even when nothing is missing).
    static func loadKit(modelFolder folder: URL, tokenizerFolder: URL) async throws -> WhisperKit {
        let config = WhisperKitConfig(
            // Without tokenizerFolder, swift-transformers' HubApi defaults to
            // ~/Documents/huggingface → TCC "access Documents" prompt per binary.
            modelFolder: folder.path, tokenizerFolder: tokenizerFolder,
            verbose: false, logLevel: .error,
            prewarm: false, load: false, download: false
        )
        let kit = try await PromptSafeWhisperKit(config)
        try Task.checkCancellation()
        try await kit.loadModels()
        try Task.checkCancellation()
        try await kit.prewarmModels()
        return kit
    }
}
