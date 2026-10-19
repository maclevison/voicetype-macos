import XCTest
import CryptoKit
import Core
@testable import VoiceType

/// Fails every request on the shared session, where WhisperKit asks the
/// repository for its file list before downloading anything.
private final class OfflineURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    static var requests: Int { lock.withLock { count } }
    static func reset() { lock.withLock { count = 0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

/// Counts the injected Whisper download and Core ML load calls.
private final class WhisperCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var downloadCount = 0
    private var loadCount = 0
    var downloads: Int { lock.withLock { downloadCount } }
    var loads: Int { lock.withLock { loadCount } }
    func downloaded() { lock.withLock { downloadCount += 1 } }
    func loaded() { lock.withLock { loadCount += 1 } }
}

/// Holds a fake Core ML load open until the test lets it end.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Error>?
    private var outcome: Result<Void, Error>?

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let outcome { continuation.resume(with: outcome) } else { waiter = continuation }
            }
        }
    }

    func open(_ result: Result<Void, Error> = .success(())) {
        lock.withLock {
            if let waiter { waiter.resume(with: result) } else { outcome = result }
            waiter = nil
        }
    }
}

/// HubApi's downloader cancelled before it registered its worker: the call
/// returns at cancellation, but the worker was never cancelled. After a silence
/// longer than any quiet period it finishes a file the way `moveDownloadedFile`
/// does, in the `downloadBase` it was given: removes the destination, recreates
/// the folders, moves the file in.
private final class OrphanWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    var done: Bool { lock.withLock { finished } }

    func download(silence: UInt64 = 1_200_000_000) -> LiveLocalModelLoader.WhisperDownload {
        { variant, downloadBase, _ in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
            let repo = downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            Task.detached {
                try? await Task.sleep(nanoseconds: silence)
                let fm = FileManager.default
                for path in ["AudioEncoder.mlmodelc/weights/weight.bin", "config.json"] {
                    let moved = repo.appendingPathComponent(variant).appendingPathComponent(path)
                    let record = repo.appendingPathComponent(".cache/huggingface/download/\(variant)/\(path).metadata")
                    for file in [moved, record] {
                        try? fm.removeItem(at: file)
                        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? Data("stale".utf8).write(to: file)
                    }
                }
                self.lock.withLock { self.finished = true }
            }
            return repo.appendingPathComponent(variant)
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

private final class StubBackend: LocalSpeechBackend, @unchecked Sendable {
    func transcribe(samples: [Float], lang: String, vocabulary: String?) async throws -> String { "" }
}

@MainActor
final class LiveLocalModelLoaderTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default

    private let smallID = "openai_whisper-small"
    private let turboID = "openai_whisper-large-v3-v20240930_turbo_632MB"
    private let turboSiblingID = "openai_whisper-large-v3-v20240930_turbo"

    override func setUp() async throws {
        base = fm.temporaryDirectory.appendingPathComponent("LiveLocalModelLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: base)
    }

    private var whisperRepo: URL { base.appendingPathComponent("models/argmaxinc/whisperkit-coreml") }

    private func makeDir(_ url: URL) throws {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func makeFile(_ url: URL) throws {
        try makeDir(url.deletingLastPathComponent())
        XCTAssertTrue(fm.createFile(atPath: url.path, contents: Data("x".utf8)))
    }

    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    private func model(_ id: String) throws -> LocalModel {
        try XCTUnwrap(LocalModelCatalog.model(id: id))
    }

    func test_delete_whisper_removes_model_and_its_partials_only() throws {
        let turbo = whisperRepo.appendingPathComponent(turboID)
        let turboCache = whisperRepo.appendingPathComponent(".cache/huggingface/download/\(turboID)")
        let sibling = whisperRepo.appendingPathComponent(turboSiblingID)
        let siblingCache = whisperRepo.appendingPathComponent(".cache/huggingface/download/\(turboSiblingID)")
        let small = whisperRepo.appendingPathComponent(smallID)
        let tokenizer = base.appendingPathComponent("models/openai/whisper-small/tokenizer.json")
        try makeDir(turbo.appendingPathComponent("AudioEncoder.mlmodelc"))
        try makeFile(turboCache.appendingPathComponent("x.abc.incomplete"))
        try makeDir(sibling.appendingPathComponent("AudioEncoder.mlmodelc"))
        try makeFile(siblingCache.appendingPathComponent("y.def.incomplete"))
        try makeDir(small.appendingPathComponent("AudioEncoder.mlmodelc"))
        try makeFile(tokenizer)

        LiveLocalModelLoader(modelsDirectory: base).deleteFiles(try model(turboID))

        XCTAssertFalse(exists(turbo))
        XCTAssertFalse(exists(turboCache))
        XCTAssertTrue(exists(sibling))
        XCTAssertTrue(exists(siblingCache))
        XCTAssertTrue(exists(small))
        XCTAssertTrue(exists(tokenizer))
    }

    func test_delete_parakeet_removes_folder_including_partials() throws {
        let parakeet = base.appendingPathComponent("parakeet-ultra")
        try makeDir(parakeet.appendingPathComponent("Encoder.mlmodelc"))
        try makeFile(parakeet.appendingPathComponent("x.partial"))
        try makeDir(whisperRepo.appendingPathComponent(smallID))

        LiveLocalModelLoader(modelsDirectory: base).deleteFiles(try model("parakeet-ultra"))

        XCTAssertFalse(exists(parakeet))
        XCTAssertTrue(exists(base.appendingPathComponent("models")))
        XCTAssertTrue(exists(whisperRepo.appendingPathComponent(smallID)))
    }

    // QA F14: an interrupted download has every folder, so the folders made
    // a partial bundle look downloaded, and Cancel kept it.
    func test_isDownloaded_whisper_requires_completion_marker() throws {
        let loader = LiveLocalModelLoader(modelsDirectory: base)
        let turbo = try model(turboID)
        let folder = whisperRepo.appendingPathComponent(turboID)

        XCTAssertFalse(loader.isDownloaded(turbo))
        try makeDir(folder.appendingPathComponent("AudioEncoder.mlmodelc"))
        try makeDir(folder.appendingPathComponent("TextDecoder.mlmodelc"))
        XCTAssertFalse(loader.isDownloaded(turbo))
        // An earlier build left the marker empty, after a finished download too.
        XCTAssertTrue(fm.createFile(atPath: folder.appendingPathComponent(LiveLocalModelLoader.completeMarker).path, contents: nil))
        XCTAssertTrue(loader.isDownloaded(turbo))
        try markComplete(folder)
        XCTAssertTrue(loader.isDownloaded(turbo))
        XCTAssertFalse(loader.isDownloaded(try model(smallID)))
    }

    /// What an interrupted download leaves: every compiled-model folder and its
    /// graph metadata, but the encoder weights never arrived.
    private func makeInterruptedBundle(_ id: String) throws -> URL {
        let folder = whisperRepo.appendingPathComponent(id)
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let compiled = folder.appendingPathComponent("\(name).mlmodelc")
            for file in ["model.mil", "coremldata.bin", "metadata.json"] {
                try makeFile(compiled.appendingPathComponent(file))
            }
            if name != "AudioEncoder" {
                try makeFile(compiled.appendingPathComponent("weights/weight.bin"))
            }
        }
        return folder
    }

    // Regression (review 6 r2): Core ML crashes loading a bundle without its
    // weights, so only a finished download is loaded straight from disk.
    func test_interrupted_whisper_bundle_is_not_a_complete_bundle() throws {
        let loader = LiveLocalModelLoader(modelsDirectory: base)
        let turbo = try model(turboID)
        let folder = try makeInterruptedBundle(turboID)

        XCTAssertFalse(loader.isDownloaded(turbo))
        XCTAssertNil(loader.completeBundle(turbo))

        try markComplete(folder)
        XCTAssertEqual(loader.completeBundle(turbo)?.standardizedFileURL, folder.standardizedFileURL)
        XCTAssertNil(loader.completeBundle(try model(smallID)))
    }

    func test_offline_load_of_interrupted_bundle_fails_through_download_and_keeps_files() async throws {
        let loader = LiveLocalModelLoader(modelsDirectory: base)
        let turbo = try model(turboID)
        let folder = try makeInterruptedBundle(turboID)
        OfflineURLProtocol.reset()
        URLProtocol.registerClass(OfflineURLProtocol.self)
        defer { URLProtocol.unregisterClass(OfflineURLProtocol.self) }

        do {
            _ = try await loader.load(turbo) { _ in }
            XCTFail("an offline load of an interrupted bundle cannot succeed")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }

        XCTAssertGreaterThan(OfflineURLProtocol.requests, 0, "went to the download, which repairs the bundle")
        XCTAssertTrue(exists(folder.appendingPathComponent("AudioEncoder.mlmodelc/model.mil")))
        XCTAssertTrue(exists(folder.appendingPathComponent("TextDecoder.mlmodelc/weights/weight.bin")))
        XCTAssertNil(loader.completeBundle(turbo))
    }

    private func loader(
        _ calls: WhisperCalls, gate: Gate? = nil, download: @escaping LiveLocalModelLoader.WhisperDownload
    ) -> LiveLocalModelLoader {
        LiveLocalModelLoader(
            modelsDirectory: base,
            downloadWhisper: { variant, downloadBase, onProgress in
                calls.downloaded()
                return try await download(variant, downloadBase, onProgress)
            },
            loadWhisper: { _, _ in
                calls.loaded()
                try await gate?.wait()
                return StubBackend()
            }
        )
    }

    private func records(_ id: String) -> URL {
        whisperRepo.appendingPathComponent(".cache/huggingface/download/\(id)")
    }

    private nonisolated static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A finished download: every file with the record the downloader writes,
    /// a SHA-256 etag for LFS files (weights), the git blob SHA-1 for the rest.
    private func makeIntactBundle(_ id: String) throws -> URL {
        try Self.writeIntactBundle(id, under: base)
    }

    /// What a finished download leaves under `root` (a `downloadBase`).
    @discardableResult
    private nonisolated static func writeIntactBundle(_ id: String, under root: URL) throws -> URL {
        let fm = FileManager.default
        let repo = root.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
        let folder = repo.appendingPathComponent(id)
        var files = ["config.json": Data("{}".utf8)]
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            files["\(name).mlmodelc/model.mil"] = Data("program \(name)".utf8)
            files["\(name).mlmodelc/weights/weight.bin"] = Data(repeating: 7, count: 4096)
        }
        for (path, content) in files {
            try fm.createDirectory(at: folder.appendingPathComponent(path).deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: folder.appendingPathComponent(path))
            let etag: String
            if path.hasSuffix(".bin") {
                etag = hex(SHA256.hash(data: content))
            } else {
                etag = hex(Insecure.SHA1.hash(data: Data("blob \(content.count)\0".utf8) + content))
            }
            let record = repo.appendingPathComponent(".cache/huggingface/download/\(id)/\(path).metadata")
            try fm.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("\(String(repeating: "a", count: 40))\n\(etag)\n1792286632.0\n".utf8).write(to: record)
        }
        return folder
    }

    /// Every regular file under `folder`, with its content.
    private func contents(of folder: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for path in WhisperBundleIntegrity.files(in: folder) {
            files[path] = try Data(contentsOf: folder.appendingPathComponent(path))
        }
        return files
    }

    // Review 7 qa r3: cancelled before HubApi registered its worker, the
    // worker is never cancelled and finishes its file later, removing the
    // destination first. With every attempt in the same folders, that removed
    // the weights the next attempt of the same model had just downloaded.
    func test_cancelled_attempt_never_touches_the_next_attempt_of_the_same_model() async throws {
        let turbo = turboID
        let calls = WhisperCalls(), orphan = OrphanWorker(), attempts = Counter()
        let orphaned = orphan.download()
        let live = loader(calls) { variant, downloadBase, onProgress in
            guard variant == turbo else { throw URLError(.notConnectedToInternet) }
            if attempts.next() == 1 { return try await orphaned(variant, downloadBase, onProgress) }
            return try Self.writeIntactBundle(variant, under: downloadBase)
        }
        let manager = LocalModelManager(loader: live, models: LocalModelCatalog.all, persist: { _ in })

        manager.bootstrap(selectedID: turboID)
        try await waitUntil { calls.downloads > 0 }
        manager.cancel()
        manager.select(turboID)
        try await waitUntil { manager.activeModel?.id == turbo }
        let published = try contents(of: whisperRepo)
        try await waitUntil { orphan.done }

        XCTAssertEqual(try contents(of: whisperRepo), published, "the cancelled attempt changed the new one's files")
        let damaged = await WhisperBundleIntegrity.damagedFiles(
            in: whisperRepo.appendingPathComponent(turboID), metadataFolder: records(turboID),
            expected: [], ignoring: [LiveLocalModelLoader.completeMarker]
        )
        XCTAssertEqual(damaged, [])
    }

    /// Polls until `condition` holds, failing instead of hanging.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "timed out")
    }

    private var downloads: URL { base.appendingPathComponent(".voicetype-downloads") }

    /// What a download that found every file already in `downloadBase` returns.
    private static let foundInPlace: LiveLocalModelLoader.WhisperDownload = { variant, downloadBase, _ in
        downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)")
    }

    // QA F14 + review 7 qa r3: a download resumed at launch and cancelled
    // midway stayed on disk with its row "Baixado", and the SDK's worker may go
    // on writing after the cancel, past any quiet period.
    func test_cancel_at_launch_of_resumed_download_removes_its_partials() async throws {
        let turbo = turboID
        let folder = try makeInterruptedBundle(turboID)
        let earlier = downloads.appendingPathComponent("\(turboID)/earlier-launch")
        let partial = "models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/\(turboID)/TextDecoder.mlmodelc/weights/weight.bin.abc.incomplete"
        try makeFile(earlier.appendingPathComponent(partial))
        let calls = WhisperCalls(), orphan = OrphanWorker(), resumed = Counter()
        let orphaned = orphan.download()
        let live = loader(calls) { variant, downloadBase, onProgress in
            guard variant == turbo else { throw URLError(.notConnectedToInternet) }
            if FileManager.default.fileExists(atPath: downloadBase.appendingPathComponent(partial).path) { _ = resumed.next() }
            return try await orphaned(variant, downloadBase, onProgress)
        }
        let manager = LocalModelManager(loader: live, models: LocalModelCatalog.all, persist: { _ in })

        XCTAssertEqual(manager.selection.status(of: turboID), .notDownloaded)
        manager.bootstrap(selectedID: turboID)
        XCTAssertEqual(manager.selection.status(of: turboID), .downloading(0))
        try await waitUntil { calls.downloads > 0 }
        XCTAssertEqual(resumed.next(), 2, "resumed the earlier launch's download")
        manager.cancel()
        try await waitUntil { orphan.done }

        XCTAssertFalse(exists(folder))
        XCTAssertFalse(exists(records(turboID)))
        XCTAssertFalse(exists(earlier))
        XCTAssertEqual(manager.selection.status(of: turboID), .notDownloaded)
        // Only what the orphaned worker wrote after the cancel, in the cancelled attempt's own folder.
        let left = WhisperBundleIntegrity.files(in: downloads).map { $0.split(separator: "/").dropFirst(2).joined(separator: "/") }
        XCTAssertEqual(Set(left), [
            "models/argmaxinc/whisperkit-coreml/\(turboID)/AudioEncoder.mlmodelc/weights/weight.bin",
            "models/argmaxinc/whisperkit-coreml/\(turboID)/config.json",
            "models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/\(turboID)/AudioEncoder.mlmodelc/weights/weight.bin.metadata",
            "models/argmaxinc/whisperkit-coreml/.cache/huggingface/download/\(turboID)/config.json.metadata",
        ])
        XCTAssertEqual(calls.loads, 0)
    }

    // QA F13: quitting during a download resumes it at the next launch.
    func test_download_of_an_earlier_launch_resumes_and_moves_in_place() async throws {
        let turbo = try model(turboID)
        let earlier = downloads.appendingPathComponent("\(turboID)/earlier-launch")
        let folder = try Self.writeIntactBundle(turboID, under: earlier)
        try fm.removeItem(at: folder.appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin"))
        let calls = WhisperCalls()
        let online = loader(calls) { variant, downloadBase, _ in
            let fetched = downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)/TextDecoder.mlmodelc/weights/weight.bin")
            guard FileManager.default.fileExists(atPath: fetched.path) else { throw URLError(.cannotOpenFile) }
            return try Self.writeIntactBundle(variant, under: downloadBase)
        }

        _ = try await online.load(turbo) { _ in }

        XCTAssertEqual(calls.loads, 1)
        XCTAssertNotNil(online.completeBundle(turbo))
        XCTAssertTrue(exists(whisperRepo.appendingPathComponent("\(turboID)/AudioEncoder.mlmodelc/weights/weight.bin")))
        XCTAssertEqual(WhisperBundleIntegrity.files(in: downloads), [])
    }

    // Review 7 qa r3: a folder of this launch belongs to a cancelled attempt
    // whose worker may still write there, so it is never resumed.
    func test_cancelled_download_of_this_launch_is_never_resumed() async throws {
        let turbo = try model(turboID)
        let calls = WhisperCalls(), orphan = OrphanWorker()
        let cancelled = loader(calls, download: orphan.download(silence: 100_000_000))
        let task = Task { try await cancelled.load(turbo) { _ in } }
        while calls.downloads == 0 { await Task.yield() }
        task.cancel()
        _ = await task.result
        try await waitUntil { orphan.done }
        XCTAssertFalse(WhisperBundleIntegrity.files(in: downloads).isEmpty, "the worker wrote after the cancel")

        let next = loader(calls) { variant, downloadBase, _ in
            let stale = downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)/config.json")
            guard !FileManager.default.fileExists(atPath: stale.path) else { throw URLError(.dataNotAllowed) }
            return try Self.writeIntactBundle(variant, under: downloadBase)
        }
        _ = try await next.load(turbo) { _ in }

        XCTAssertNotNil(next.completeBundle(turbo))
        XCTAssertEqual(WhisperBundleIntegrity.files(in: downloads), [])
    }

    /// Waits for the fake Core ML load to start, failing instead of hanging.
    private func waitUntilLoading(_ calls: WhisperCalls) async throws {
        for _ in 0..<2_000 where calls.loads == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try XCTSkipUnless(calls.loads > 0, "the load never reached Core ML")
    }

    /// The marker a finished download leaves: the inventory of the bundle.
    private func markComplete(_ folder: URL) throws {
        let files = WhisperBundleIntegrity.files(in: folder).filter { $0 != LiveLocalModelLoader.completeMarker }
        try files.sorted().joined(separator: "\n")
            .write(to: folder.appendingPathComponent(LiveLocalModelLoader.completeMarker), atomically: true, encoding: .utf8)
    }

    // Regression (review 6 r3): cancelled midway, the downloader returns the
    // folder without throwing. That partial bundle must not be marked complete,
    // or the next load hands it to Core ML, which crashes.
    func test_cancelled_resumed_download_is_not_marked_complete() async throws {
        let turbo = try model(turboID)
        let folder = try makeInterruptedBundle(turboID)
        let calls = WhisperCalls()
        let cancelling = loader(calls) { _, _, _ in
            // Like `HubApi.snapshot`: stop at cancellation and return, no throw.
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000) }
            return folder
        }

        let task = Task { try await cancelling.load(turbo) { _ in } }
        while calls.downloads == 0 { await Task.yield() }
        task.cancel()
        let result = await task.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(calls.loads, 0, "a cancelled download never reaches Core ML")
        XCTAssertNil(cancelling.completeBundle(turbo))
        XCTAssertFalse(exists(folder.appendingPathComponent(LiveLocalModelLoader.completeMarker)))
        XCTAssertFalse(exists(folder.appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin")))
        XCTAssertFalse(cancelling.isDownloaded(turbo))

        // The next attempt goes through the download (the repair) and, offline,
        // fails without entering Core ML.
        let offline = loader(calls) { _, _, _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await offline.load(turbo) { _ in }
            XCTFail("an offline repair cannot succeed")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        XCTAssertEqual(calls.downloads, 2)
        XCTAssertEqual(calls.loads, 0)
    }

    func test_finished_download_is_marked_complete_and_later_loads_from_disk() async throws {
        let turbo = try model(turboID)
        let folder = try makeIntactBundle(turboID)
        let calls = WhisperCalls()
        let online = loader(calls, download: Self.foundInPlace)

        _ = try await online.load(turbo) { _ in }
        XCTAssertEqual(calls.downloads, 1)
        XCTAssertEqual(calls.loads, 1)
        XCTAssertNotNil(online.completeBundle(turbo))

        let offline = loader(calls) { _, _, _ in throw URLError(.notConnectedToInternet) }
        _ = try await offline.load(turbo) { _ in }
        XCTAssertEqual(calls.downloads, 1, "a complete bundle loads without the repository")
        XCTAssertEqual(calls.loads, 2)
    }

    func test_integrity_accepts_intact_bundle_and_flags_files_without_record() async throws {
        let folder = try makeIntactBundle(turboID)
        try markComplete(folder)
        let clean = await WhisperBundleIntegrity.damagedFiles(
            in: folder, metadataFolder: records(turboID), expected: [], ignoring: [LiveLocalModelLoader.completeMarker]
        )
        XCTAssertEqual(clean, [])

        try makeFile(folder.appendingPathComponent("stray.bin"))
        let flagged = await WhisperBundleIntegrity.damagedFiles(
            in: folder, metadataFolder: records(turboID), expected: [], ignoring: [LiveLocalModelLoader.completeMarker]
        )
        XCTAssertEqual(flagged, ["stray.bin"])
    }

    // QA F15: a complete bundle whose weights were emptied, truncated or
    // corrupted afterwards crashed the app inside Core ML. The load now fails
    // with a reason before Core ML, and drops just the damaged files.
    func test_damaged_weights_of_complete_bundle_fail_before_core_ml() async throws {
        let turbo = try model(turboID)
        let encoder = "AudioEncoder.mlmodelc/weights/weight.bin"
        let damage: [(Data) -> Data] = [
            { _ in Data() },                                       // `: > weight.bin`
            { $0.prefix(1000) },                                   // truncated
            { var d = $0; d[100] ^= 0xFF; return d },              // same size, one byte off
        ]
        for corrupt in damage {
            let folder = try makeIntactBundle(turboID)
            try markComplete(folder)
            let weights = folder.appendingPathComponent(encoder)
            try corrupt(try Data(contentsOf: weights)).write(to: weights)
            let calls = WhisperCalls()
            let offline = loader(calls) { _, _, _ in throw URLError(.notConnectedToInternet) }

            do {
                _ = try await offline.load(turbo) { _ in }
                XCTFail("a damaged bundle cannot load")
            } catch {
                XCTAssertEqual(error as? LocalModelLoadError, .damagedFiles)
                XCTAssertEqual(error.localizedDescription, SettingsStrings.localModelDamaged)
            }
            XCTAssertEqual(calls.loads, 0, "never handed to Core ML")
            XCTAssertEqual(calls.downloads, 0)
            XCTAssertFalse(exists(weights))
            XCTAssertFalse(exists(records(turboID).appendingPathComponent(encoder + ".metadata")))
            XCTAssertNil(offline.completeBundle(turbo))
            XCTAssertTrue(exists(folder.appendingPathComponent("TextDecoder.mlmodelc/weights/weight.bin")))
            XCTAssertFalse(offline.isDownloaded(turbo), "without its marker until a download repairs it")
            try fm.removeItem(at: whisperRepo)
        }
    }

    func test_integrity_flags_files_missing_from_records_or_inventory() async throws {
        let folder = try makeIntactBundle(turboID)
        let encoder = "AudioEncoder.mlmodelc/weights/weight.bin"
        try fm.removeItem(at: folder.appendingPathComponent(encoder))
        let byRecord = await WhisperBundleIntegrity.damagedFiles(
            in: folder, metadataFolder: records(turboID), expected: [], ignoring: []
        )
        XCTAssertEqual(byRecord, [encoder])

        try fm.removeItem(at: records(turboID).appendingPathComponent(encoder + ".metadata"))
        let byInventory = await WhisperBundleIntegrity.damagedFiles(
            in: folder, metadataFolder: records(turboID), expected: [encoder], ignoring: []
        )
        XCTAssertEqual(byInventory, [encoder])
    }

    // Review 7 qa r1: a file that is gone was never checked, so a complete
    // bundle missing a weight still reached Core ML, which crashes.
    func test_missing_weight_of_complete_bundle_fails_before_core_ml() async throws {
        let turbo = try model(turboID)
        let encoder = "AudioEncoder.mlmodelc/weights/weight.bin"
        for alsoDropRecord in [false, true] {
            let folder = try makeIntactBundle(turboID)
            try markComplete(folder)
            try fm.removeItem(at: folder.appendingPathComponent(encoder))
            if alsoDropRecord {
                try fm.removeItem(at: records(turboID).appendingPathComponent(encoder + ".metadata"))
            }
            let calls = WhisperCalls()
            let offline = loader(calls) { _, _, _ in throw URLError(.notConnectedToInternet) }

            do {
                _ = try await offline.load(turbo) { _ in }
                XCTFail("a bundle missing a weight cannot load")
            } catch {
                XCTAssertEqual(error as? LocalModelLoadError, .damagedFiles)
            }
            XCTAssertEqual(calls.loads, 0, "never handed to Core ML")
            XCTAssertEqual(calls.downloads, 0)
            XCTAssertNil(offline.completeBundle(turbo))
            try fm.removeItem(at: whisperRepo)
        }
    }

    func test_marker_without_inventory_is_not_a_complete_bundle() async throws {
        let turbo = try model(turboID)
        let folder = try makeIntactBundle(turboID)
        XCTAssertTrue(fm.createFile(atPath: folder.appendingPathComponent(LiveLocalModelLoader.completeMarker).path, contents: nil))
        let calls = WhisperCalls()
        let offline = loader(calls) { _, _, _ in throw URLError(.notConnectedToInternet) }

        XCTAssertNil(offline.completeBundle(turbo))
        do {
            _ = try await offline.load(turbo) { _ in }
            XCTFail("an offline load without inventory cannot succeed")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet, "goes through the download")
        }
        XCTAssertEqual(calls.loads, 0)

        // Online, the checked download writes the inventory, and later loads skip the repository.
        let online = loader(calls, download: Self.foundInPlace)
        _ = try await online.load(turbo) { _ in }
        XCTAssertNotNil(online.completeBundle(turbo))
        _ = try await offline.load(turbo) { _ in }
        XCTAssertEqual(calls.loads, 2)
    }

    func test_download_that_kept_a_damaged_file_is_not_marked_complete() async throws {
        let turbo = try model(turboID)
        let folder = try makeIntactBundle(turboID)
        try Data().write(to: folder.appendingPathComponent("TextDecoder.mlmodelc/weights/weight.bin"))
        let calls = WhisperCalls()
        let online = loader(calls, download: Self.foundInPlace)

        do {
            _ = try await online.load(turbo) { _ in }
            XCTFail("a damaged bundle cannot load")
        } catch {
            XCTAssertEqual(error as? LocalModelLoadError, .damagedFiles)
        }
        XCTAssertEqual(calls.downloads, 1)
        XCTAssertEqual(calls.loads, 0)
        XCTAssertNil(online.completeBundle(turbo))
        XCTAssertFalse(exists(folder.appendingPathComponent("TextDecoder.mlmodelc/weights/weight.bin")), "dropped, to be fetched again")
        XCTAssertTrue(exists(folder.appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin")))
    }

    // QA F15/K8: what the hashes cannot catch still must not crash every
    // launch. A load under way when the app dies is reported at the next one.
    func test_load_under_way_when_app_dies_is_reported_at_next_launch() async throws {
        let turbo = try model(turboID)
        try markComplete(try makeIntactBundle(turboID))
        let calls = WhisperCalls(), gate = Gate()
        let running = loader(calls, gate: gate) { _, _, _ in throw URLError(.notConnectedToInternet) }

        let task = Task { try await running.load(turbo) { _ in } }
        try await waitUntilLoading(calls)
        let relaunched = LiveLocalModelLoader(modelsDirectory: base)
        XCTAssertEqual(relaunched.crashedModels(LocalModelCatalog.all), [turboID])
        XCTAssertEqual(relaunched.crashedModels(LocalModelCatalog.all), [turboID], "stays until it loads")

        gate.open()
        _ = try await task.value
        XCTAssertEqual(relaunched.crashedModels(LocalModelCatalog.all), [], "a successful load clears it")
    }

    func test_quit_or_thrown_error_during_load_is_not_a_crash() async throws {
        let turbo = try model(turboID)
        try markComplete(try makeIntactBundle(turboID))
        let offline: LiveLocalModelLoader.WhisperDownload = { _, _, _ in throw URLError(.notConnectedToInternet) }

        let calls = WhisperCalls(), gate = Gate()
        let quitting = loader(calls, gate: gate, download: offline)
        let task = Task { try await quitting.load(turbo) { _ in } }
        try await waitUntilLoading(calls)
        quitting.endSession()
        XCTAssertEqual(quitting.crashedModels(LocalModelCatalog.all), [])
        gate.open()
        _ = try await task.value

        let failing = Gate()
        failing.open(.failure(FakeLoadError()))
        _ = try? await loader(WhisperCalls(), gate: failing, download: offline).load(turbo) { _ in }
        XCTAssertEqual(quitting.crashedModels(LocalModelCatalog.all), [])
    }

    func test_delete_clears_crash_record() async throws {
        let turbo = try model(turboID)
        try markComplete(try makeIntactBundle(turboID))
        let calls = WhisperCalls(), gate = Gate()
        let running = loader(calls, gate: gate) { _, _, _ in throw URLError(.notConnectedToInternet) }
        let task = Task { try await running.load(turbo) { _ in } }
        try await waitUntilLoading(calls)
        XCTAssertEqual(running.crashedModels(LocalModelCatalog.all), [turboID])
        gate.open(.failure(FakeLoadError()))
        _ = try? await task.value

        running.deleteFiles(turbo)
        XCTAssertEqual(running.crashedModels(LocalModelCatalog.all), [])
    }
}

private struct FakeLoadError: Error {}
