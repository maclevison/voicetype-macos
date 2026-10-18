import Foundation
import Core
import FluidAudio
import os

/// A loaded on-device speech model, ready to transcribe 16 kHz mono samples.
protocol LocalSpeechBackend: AnyObject, Sendable {
    func transcribe(samples: [Float], lang: String, vocabulary: String?) async throws -> String
}

enum LocalModelLoadProgress: Sendable {
    case downloading(Double)
    case preparing
}

enum LocalModelLoadError: LocalizedError {
    /// Files on disk do not match their recorded hashes; they were removed, and
    /// picking the model again downloads them.
    case damagedFiles

    var errorDescription: String? { SettingsStrings.localModelDamaged }
}

/// Downloads, loads and deletes the catalog's models. Never called with a
/// load and a delete of the same id at once: `LocalModelManager` serializes them.
@MainActor
protocol LocalModelLoading {
    func isDownloaded(_ model: LocalModel) -> Bool
    func load(
        _ model: LocalModel, progress: @escaping @Sendable (LocalModelLoadProgress) -> Void
    ) async throws -> any LocalSpeechBackend
    func deleteFiles(_ model: LocalModel)
    /// Models whose load was under way when the app last died (Core ML crashes
    /// on damaged weights instead of throwing) and that have not loaded since.
    func crashedModels(_ models: [LocalModel]) -> Set<String>
    /// The app quits normally: a load under way now is not a crash.
    func endSession()
}

/// Every model lives under `modelsDirectory`:
/// - Whisper: `models/argmaxinc/whisperkit-coreml/<id>` (plus `completeMarker`
///   once its download finished), with the downloader's records in
///   `models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/<id>`.
///   Each download attempt gets a folder of its own,
///   `.voicetype-downloads/<id>/<launch>-<uuid>/` (the same layout inside),
///   and only a download that was not cancelled is moved in place.
///   Tokenizers (`models/openai/…`) are shared and never deleted.
/// - Parakeet: `parakeet-ultra/`, partials (`*.partial`) included.
/// - `.voicetype-loading-<id>` while Core ML loads a model, and
///   `.voicetype-crashed-<id>` when the app died during that load.
@MainActor
struct LiveLocalModelLoader: LocalModelLoading {
    private static let logger = Logger(subsystem: "dev.voicetype.app", category: "LiveLocalModelLoader")

    /// Fetches the missing files of a Whisper model into `downloadBase`, under
    /// `models/argmaxinc/whisperkit-coreml/<variant>`.
    typealias WhisperDownload = @Sendable (
        _ variant: String, _ downloadBase: URL, _ onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL
    /// Loads the Whisper model in a folder into Core ML.
    typealias WhisperLoad = @Sendable (_ modelFolder: URL, _ tokenizerFolder: URL) async throws -> any LocalSpeechBackend

    /// Written in a Whisper model's folder once a download that was not
    /// cancelled returned and every file matched its record, i.e. every file is
    /// on disk. It lists those files, one path per line: the inventory later
    /// loads check against. The folders alone prove nothing: an interrupted
    /// download leaves them without weights, and Core ML crashes (it does not
    /// throw) loading that.
    static let completeMarker = ".voicetype-complete"

    /// Names this launch's download folders: a folder of an earlier launch
    /// belongs to a process that is gone, so nothing writes there any more.
    nonisolated static let launchID = UUID().uuidString

    let modelsDirectory: URL
    private let launch: String
    private let downloadWhisper: WhisperDownload
    private let loadWhisper: WhisperLoad

    nonisolated init(
        modelsDirectory: URL = WhisperKitLoader.modelsDirectory,
        launch: String = LiveLocalModelLoader.launchID,
        downloadWhisper: @escaping WhisperDownload = { variant, downloadBase, onProgress in
            try await WhisperKitLoader.download(variant: variant, downloadBase: downloadBase, onProgress: onProgress)
        },
        loadWhisper: @escaping WhisperLoad = { folder, tokenizerFolder in
            WhisperKitBackend(kit: try await WhisperKitLoader.loadKit(modelFolder: folder, tokenizerFolder: tokenizerFolder))
        }
    ) {
        self.modelsDirectory = modelsDirectory
        self.launch = launch
        self.downloadWhisper = downloadWhisper
        self.loadWhisper = loadWhisper
    }

    private func whisperRepo(in root: URL) -> URL {
        root.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    private func whisperFolder(_ id: String, in root: URL? = nil) -> URL {
        whisperRepo(in: root ?? modelsDirectory).appendingPathComponent(id, isDirectory: true)
    }

    private func whisperPartials(_ id: String, in root: URL? = nil) -> URL {
        whisperRepo(in: root ?? modelsDirectory).appendingPathComponent(".cache/huggingface/download", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    private func whisperDownloads(_ id: String) -> URL {
        modelsDirectory.appendingPathComponent(".voicetype-downloads", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    private var parakeetFolder: URL {
        modelsDirectory.appendingPathComponent("parakeet-ultra", isDirectory: true)
    }

    private func loadingSentinel(_ id: String) -> URL {
        modelsDirectory.appendingPathComponent(".voicetype-loading-\(id)")
    }

    private func crashRecord(_ id: String) -> URL {
        modelsDirectory.appendingPathComponent(".voicetype-crashed-\(id)")
    }

    /// A Whisper model is downloaded once it has its completion marker (even
    /// an empty one, from an earlier build): an interrupted download has every
    /// folder too, and counting it would make Cancel keep its partial files.
    func isDownloaded(_ model: LocalModel) -> Bool {
        switch model.engine {
        case .whisperKit:
            let marker = whisperFolder(model.id).appendingPathComponent(Self.completeMarker)
            return FileManager.default.fileExists(atPath: marker.path)
        case .parakeet:
            return AsrModels.modelsExist(at: parakeetFolder, version: .ultra)
        }
    }

    /// The folder of a Whisper model whose download finished, which can be
    /// loaded without asking the repository anything; nil otherwise. A marker
    /// without an inventory (written by an earlier build) does not count.
    func completeBundle(_ model: LocalModel) -> URL? {
        guard model.engine == .whisperKit else { return nil }
        let folder = whisperFolder(model.id)
        return inventory(of: folder).isEmpty ? nil : folder
    }

    private func inventory(of folder: URL) -> Set<String> {
        let marker = folder.appendingPathComponent(Self.completeMarker)
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map(String.init))
    }

    func load(
        _ model: LocalModel, progress: @escaping @Sendable (LocalModelLoadProgress) -> Void
    ) async throws -> any LocalSpeechBackend {
        switch model.engine {
        case .whisperKit:
            if let folder = completeBundle(model) {
                try await checkIntegrity(of: folder, records: whisperPartials(model.id))
                // Offline or with the repository down, the files on disk still load.
                do {
                    return try await guardedLoad(model) { try await loadWhisper(folder, modelsDirectory) }
                } catch {
                    try Task.checkCancellation()
                    // Fall through: the download fetches whatever file is missing.
                    Self.logger.error("Local load of \(model.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            let attempt = try prepareDownload(model.id)
            do {
                _ = try await downloadWhisper(model.id, attempt) { fraction in
                    progress(fraction >= 1 ? .preparing : .downloading(fraction))
                }
                // Cancelled midway, the downloader returns without throwing
                // (`HubApi.snapshot`), so only an attempt still running has every file.
                try Task.checkCancellation()
                // The downloader returns the files it already had without reading them.
                try await checkIntegrity(of: whisperFolder(model.id, in: attempt), records: whisperPartials(model.id, in: attempt))
            } catch LocalModelLoadError.damagedFiles {
                // The damaged files are gone from the download: in place, the
                // next attempt fetches only those.
                try publish(attempt, model.id)
                throw LocalModelLoadError.damagedFiles
            } catch {
                // A cancelled download may still have a task of the SDK writing
                // in `attempt` (G-037): it stays out of every other attempt.
                try? FileManager.default.removeItem(at: attempt)
                throw error
            }
            // Never cancelled, so every task the download started has ended.
            try publish(attempt, model.id)
            let folder = whisperFolder(model.id)
            return try await guardedLoad(model) { try await loadWhisper(folder, modelsDirectory) }
        case .parakeet:
            let folder = parakeetFolder
            try await AsrModels.download(to: folder, version: .ultra) { update in
                switch update.phase {
                case .listing, .downloading: progress(.downloading(update.fractionCompleted))
                case .compiling: progress(.preparing)
                }
            }
            try Task.checkCancellation()
            progress(.preparing)
            return try await guardedLoad(model) {
                let models = try await AsrModels.load(from: folder, version: .ultra)
                try Task.checkCancellation()
                let manager = AsrManager()
                try await manager.loadModels(models)
                return ParakeetBackend(manager: manager)
            }
        }
    }

    /// Throws `damagedFiles`, before Core ML ever sees them, when a file is
    /// missing or does not match its recorded hash. The damaged files and the
    /// marker are removed, so the next download fetches just those. A bundle
    /// that passes gets (or refreshes) its marker with its inventory.
    private func checkIntegrity(of folder: URL, records: URL) async throws {
        let marker = folder.appendingPathComponent(Self.completeMarker)
        let damaged = await WhisperBundleIntegrity.damagedFiles(
            in: folder, metadataFolder: records, expected: inventory(of: folder), ignoring: [Self.completeMarker]
        )
        try Task.checkCancellation()
        guard !damaged.isEmpty else {
            let files = WhisperBundleIntegrity.files(in: folder).filter { $0 != Self.completeMarker }.sorted()
            try? files.joined(separator: "\n").write(to: marker, atomically: true, encoding: .utf8)
            return
        }
        Self.logger.error("Damaged files in \(folder.lastPathComponent, privacy: .public): \(damaged.joined(separator: ", "), privacy: .public)")
        let fm = FileManager.default
        try? fm.removeItem(at: marker)
        for path in damaged {
            try? fm.removeItem(at: folder.appendingPathComponent(path))
            try? fm.removeItem(at: records.appendingPathComponent(path + ".metadata"))
        }
        throw LocalModelLoadError.damagedFiles
    }

    /// A new folder for one download attempt of `id`. HubApi's `Downloader`
    /// writes from a task of its own that a cancel neither stops nor waits for
    /// (G-037), so attempts never share files: a cancelled one can only write
    /// in its own folder, which nothing reads. The folder starts with the
    /// download an earlier launch left (its process is gone, so it resumes
    /// safely), or else with clones of the files in place, so the download
    /// fetches only what is missing. This launch's other folders are dropped.
    private func prepareDownload(_ id: String) throws -> URL {
        let fm = FileManager.default
        let root = whisperDownloads(id)
        let attempt = root.appendingPathComponent("\(launch)-\(UUID().uuidString)", isDirectory: true)
        let leftovers = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let resumed = leftovers
            .filter { !$0.lastPathComponent.hasPrefix(launch + "-") }
            .map { (folder: $0, bytes: Self.bytes(in: $0)) }
            .filter { $0.bytes > 0 }
            .max { $0.bytes < $1.bytes }?.folder
        for leftover in leftovers where leftover != resumed {
            try? fm.removeItem(at: leftover)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if let resumed {
            try fm.moveItem(at: resumed, to: attempt)
            return attempt
        }
        try fm.createDirectory(at: attempt, withIntermediateDirectories: true)
        for (from, to) in [(whisperFolder(id), whisperFolder(id, in: attempt)), (whisperPartials(id), whisperPartials(id, in: attempt))]
        where fm.fileExists(atPath: from.path) {
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: from, to: to)
        }
        return attempt
    }

    /// Moves a download that was not cancelled in place of the model's files.
    /// The records go first and the folder, with its marker, last: a launch
    /// that dies in between finds the model incomplete and resumes from the
    /// download folder, which still holds the files.
    private func publish(_ attempt: URL, _ id: String) throws {
        let fm = FileManager.default
        let folder = whisperFolder(id), records = whisperPartials(id)
        try? fm.removeItem(at: records)
        try? fm.removeItem(at: folder)
        let downloadedRecords = whisperPartials(id, in: attempt)
        if fm.fileExists(atPath: downloadedRecords.path) {
            try fm.createDirectory(at: records.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: downloadedRecords, to: records)
        }
        try fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: whisperFolder(id, in: attempt), to: folder)
        try? fm.removeItem(at: attempt)
    }

    private nonisolated static func bytes(in folder: URL) -> Int {
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let item as URL in items {
            total += (try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        }
        return total
    }

    /// Runs a Core ML load with a sentinel on disk, so that if the app dies in
    /// it the next launch knows (`crashedModels`) and does not load it again.
    private func guardedLoad(
        _ model: LocalModel, _ body: () async throws -> any LocalSpeechBackend
    ) async throws -> any LocalSpeechBackend {
        let fm = FileManager.default
        let sentinel = loadingSentinel(model.id)
        fm.createFile(atPath: sentinel.path, contents: nil)
        defer { try? fm.removeItem(at: sentinel) }
        let backend = try await body()
        try? fm.removeItem(at: crashRecord(model.id))
        return backend
    }

    func crashedModels(_ models: [LocalModel]) -> Set<String> {
        let fm = FileManager.default
        var crashed: Set<String> = []
        for model in models {
            let sentinel = loadingSentinel(model.id), record = crashRecord(model.id)
            if fm.fileExists(atPath: sentinel.path) {
                try? fm.removeItem(at: record)
                try? fm.moveItem(at: sentinel, to: record)
            }
            if fm.fileExists(atPath: record.path) { crashed.insert(model.id) }
        }
        return crashed
    }

    func endSession() {
        for model in LocalModelCatalog.all {
            try? FileManager.default.removeItem(at: loadingSentinel(model.id))
        }
    }

    func deleteFiles(_ model: LocalModel) {
        let targets: [URL]
        switch model.engine {
        case .whisperKit: targets = [whisperFolder(model.id), whisperPartials(model.id), whisperDownloads(model.id)]
        case .parakeet: targets = [parakeetFolder]
        }
        for url in targets + [crashRecord(model.id)] {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
