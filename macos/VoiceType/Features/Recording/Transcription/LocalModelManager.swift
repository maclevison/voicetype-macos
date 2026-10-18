import Foundation
import Observation
import Core
import os

/// The active model and its loaded backend, read together so a transcription
/// never pairs one model's backend with another model's capabilities.
struct LocalTranscriptionTarget: Sendable {
    let model: LocalModel
    let backend: any LocalSpeechBackend
}

/// Runs `LocalModelSelection`'s effects: loads, cancels, deletes and persists the
/// on-device dictation model. The previous model keeps transcribing until the
/// new one is ready.
@Observable
@MainActor
final class LocalModelManager {
    private static let logger = Logger(subsystem: "dev.voicetype.app", category: "LocalModelManager")

    let models: [LocalModel]
    private(set) var selection: LocalModelSelection
    private var activeTarget: LocalTranscriptionTarget?

    @ObservationIgnored private let loader: any LocalModelLoading
    @ObservationIgnored private let persist: @MainActor (String) -> Void
    @ObservationIgnored private var loadTasks: [LoadAttempt: Task<Void, Never>] = [:]
    // Last file operation (load or delete) of each model id. Every new operation
    // waits for it, so files are only deleted, or loaded again, once the previous
    // load has really ended — Core ML compilation included, which ignores cancel.
    @ObservationIgnored private var fileQueue: [String: Task<Void, Never>] = [:]

    var isReady: Bool { activeTarget != nil }
    var activeModel: LocalModel? { activeTarget?.model }

    init(
        loader: any LocalModelLoading = LiveLocalModelLoader(),
        models: [LocalModel] = LocalModelCatalog.available(
            macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        ),
        persist: @escaping @MainActor (String) -> Void
    ) {
        self.loader = loader
        self.models = models
        self.persist = persist
        let downloaded = models.filter { loader.isDownloaded($0) }.map(\.id)
        selection = LocalModelSelection(modelIDs: models.map(\.id), downloaded: Set(downloaded))
    }

    /// The only way to get a backend: one read on the main actor, model and
    /// backend together.
    func transcriptionTarget() -> LocalTranscriptionTarget? { activeTarget }

    func bootstrap(selectedID: String) {
        for id in loader.crashedModels(models) {
            Self.logger.error("The app died loading \(id, privacy: .public); not loading it at launch")
            selection.recordCrash(id, message: SettingsStrings.localModelCrashed)
        }
        run(selection.boot(selectedID: selectedID))
    }

    /// The app quits normally: a load under way is not a crash.
    func endSession() { loader.endSession() }
    func select(_ id: String) { run(selection.select(id)) }
    func cancel() { run(selection.cancel()) }
    func delete(_ id: String) { run(selection.delete(id)) }

    private func model(_ id: String) -> LocalModel? {
        models.first { $0.id == id }
    }

    private func run(_ effects: [LocalModelEffect]) {
        for effect in effects {
            switch effect {
            case .load(let attempt): startLoad(attempt)
            case .cancelLoad(let attempt): loadTasks[attempt]?.cancel()
            case .deleteFiles(let id): enqueueDelete(id)
            case .unload(let id): if activeTarget?.model.id == id { activeTarget = nil }
            case .persistSelection(let id): persist(id)
            }
        }
    }

    private func startLoad(_ attempt: LoadAttempt) {
        guard let model = model(attempt.modelID) else { return }
        let previous = fileQueue[model.id]
        let task = Task { [weak self] in
            await previous?.value
            await self?.load(model, attempt)
        }
        loadTasks[attempt] = task
        fileQueue[model.id] = task
    }

    private func load(_ model: LocalModel, _ attempt: LoadAttempt) async {
        defer { loadTasks[attempt] = nil }
        guard !Task.isCancelled, selection.pendingAttempt == attempt else { return }
        do {
            let backend = try await loader.load(model) { [weak self] update in
                Task { @MainActor in self?.progress(attempt, update) }
            }
            finish(attempt, backend)
        } catch is CancellationError {
        } catch {
            Self.logger.error("Load of \(model.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            run(selection.loadFailed(attempt, message: error.localizedDescription))
        }
    }

    private func progress(_ attempt: LoadAttempt, _ update: LocalModelLoadProgress) {
        switch update {
        case .downloading(let fraction): selection.progress(attempt, .downloading(fraction))
        case .preparing: selection.progress(attempt, .preparing)
        }
    }

    // No suspension point: the selection and the target change in the same step.
    private func finish(_ attempt: LoadAttempt, _ backend: any LocalSpeechBackend) {
        guard selection.pendingAttempt == attempt, let model = model(attempt.modelID) else { return }
        run(selection.loadSucceeded(attempt))
        activeTarget = LocalTranscriptionTarget(model: model, backend: backend)
        Self.logger.info("Local model ready: \(model.id, privacy: .public)")
    }

    private func enqueueDelete(_ id: String) {
        guard let model = model(id) else { return }
        let previous = fileQueue[id]
        fileQueue[id] = Task { [weak self] in
            await previous?.value
            self?.loader.deleteFiles(model)
        }
    }
}
