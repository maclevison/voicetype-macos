import XCTest
import Core
@testable import VoiceType

/// Records the vocabulary of every call and returns `text`. After
/// `holdNextTranscription()`, the next call stays suspended until `release()`.
final class FakeBackend: LocalSpeechBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let text: String
    private var received: [String?] = []
    private var holdsNext = false
    private var held: CheckedContinuation<Void, Never>?

    init(text: String = "") { self.text = text }

    var vocabularies: [String?] { lock.withLock { received } }
    var isHeld: Bool { lock.withLock { held != nil } }

    func holdNextTranscription() { lock.withLock { holdsNext = true } }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { held = nil }
            return held
        }
        continuation?.resume()
    }

    func transcribe(samples: [Float], lang: String, vocabulary: String?) async throws -> String {
        let holds = lock.withLock { () -> Bool in
            received.append(vocabulary)
            defer { holdsNext = false }
            return holdsNext
        }
        if holds {
            await withCheckedContinuation { continuation in lock.withLock { held = continuation } }
        }
        return text
    }
}

/// Logs `load:<id>`, `end:<id>` and `delete:<id>` in order. Each load stays
/// suspended until the test resolves it and, like a Core ML compile, ignores
/// cancellation until then.
@MainActor
final class FakeLoader: LocalModelLoading {
    var downloaded: Set<String> = []
    var crashed: Set<String> = []
    private(set) var log: [String] = []
    private var pending: [String: [CheckedContinuation<any LocalSpeechBackend, Error>]] = [:]

    func isDownloaded(_ model: LocalModel) -> Bool { downloaded.contains(model.id) }

    func load(
        _ model: LocalModel, progress: @escaping @Sendable (LocalModelLoadProgress) -> Void
    ) async throws -> any LocalSpeechBackend {
        log.append("load:\(model.id)")
        defer { log.append("end:\(model.id)") }
        return try await withCheckedThrowingContinuation { pending[model.id, default: []].append($0) }
    }

    func deleteFiles(_ model: LocalModel) {
        log.append("delete:\(model.id)")
    }

    func crashedModels(_ models: [LocalModel]) -> Set<String> { crashed }

    func endSession() { log.append("endSession") }

    @discardableResult
    func succeed(_ id: String, text: String = "") throws -> FakeBackend {
        let backend = FakeBackend(text: text)
        try next(id).resume(returning: backend)
        return backend
    }

    func fail(_ id: String, _ error: Error) throws {
        try next(id).resume(throwing: error)
    }

    func failAll() {
        for continuation in pending.values.flatMap({ $0 }) {
            continuation.resume(throwing: CancellationError())
        }
        pending = [:]
    }

    private func next(_ id: String) throws -> CheckedContinuation<any LocalSpeechBackend, Error> {
        let continuation = try XCTUnwrap(pending[id]?.first, "no load of \(id) in flight")
        pending[id]?.removeFirst()
        return continuation
    }
}

private struct FakeError: LocalizedError {
    var errorDescription: String? { "boom" }
}

@MainActor
final class LocalModelManagerTests: XCTestCase {
    private let smallID = "openai_whisper-small"
    private let turboID = "openai_whisper-large-v3-v20240930_turbo_632MB"
    private let parakeetID = "parakeet-ultra"

    private var loader: FakeLoader!
    private var persisted: [String] = []

    override func setUp() async throws {
        loader = FakeLoader()
        persisted = []
    }

    override func tearDown() async throws {
        loader.failAll()
        await settle()
    }

    private func makeManager() -> LocalModelManager {
        LocalModelManager(loader: loader, models: LocalModelCatalog.all, persist: { [weak self] id in
            self?.persisted.append(id)
        })
    }

    /// Lets the manager's main-actor tasks run until they suspend again.
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    private func readyWithSmall() async throws -> (LocalModelManager, FakeBackend) {
        try await ready(with: smallID)
    }

    private func ready(with id: String) async throws -> (LocalModelManager, FakeBackend) {
        loader.downloaded.insert(id)
        let manager = makeManager()
        manager.bootstrap(selectedID: id)
        await settle()
        let backend = try loader.succeed(id)
        await settle()
        XCTAssertEqual(manager.activeModel?.id, id)
        persisted = []
        return (manager, backend)
    }

    /// Polls until `condition` holds: the transcriber runs off the main actor.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<2_000 where !condition() {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(condition(), "timed out")
    }

    private var oneSecondOfSilence: Data {
        WavEncoder.encode(pcmInt16LE: Data(count: 32_000), sampleRate: 16_000, channels: 1)
    }

    private func count(_ entry: String) -> Int {
        loader.log.filter { $0 == entry }.count
    }

    func test_bootstrap_loads_selected_and_becomes_ready() async throws {
        loader.downloaded.insert(smallID)
        let manager = makeManager()
        manager.bootstrap(selectedID: smallID)
        await settle()
        XCTAssertFalse(manager.isReady)
        XCTAssertEqual(loader.log, ["load:\(smallID)"])

        try loader.succeed(smallID)
        await settle()

        XCTAssertTrue(manager.isReady)
        XCTAssertEqual(manager.transcriptionTarget()?.model.id, smallID)
    }

    func test_target_stays_previous_while_pending() async throws {
        let (manager, small) = try await readyWithSmall()
        manager.select(turboID)
        await settle()

        XCTAssertEqual(manager.selection.pending, turboID)
        let target = try XCTUnwrap(manager.transcriptionTarget())
        XCTAssertEqual(target.model.id, smallID)
        XCTAssertTrue(target.backend === small)
        XCTAssertTrue(manager.isReady)
    }

    func test_failure_deletes_files_and_persists_previous() async throws {
        let (manager, small) = try await readyWithSmall()
        manager.select(turboID)
        await settle()
        try loader.fail(turboID, FakeError())
        await settle()

        XCTAssertEqual(count("delete:\(turboID)"), 1)
        XCTAssertEqual(persisted, [turboID, smallID])
        XCTAssertEqual(manager.selection.status(of: turboID), .failed("boom"))
        XCTAssertTrue(manager.transcriptionTarget()?.backend === small)
    }

    func test_cancelled_load_result_is_discarded() async throws {
        let (manager, small) = try await readyWithSmall()
        manager.select(turboID)
        await settle()
        manager.cancel()
        let turbo = try loader.succeed(turboID)
        await settle()

        XCTAssertEqual(manager.activeModel?.id, smallID)
        XCTAssertTrue(manager.transcriptionTarget()?.backend === small)
        XCTAssertFalse(manager.transcriptionTarget()?.backend === turbo)
    }

    func test_cancel_waits_for_load_to_end_before_deleting() async throws {
        let (manager, _) = try await readyWithSmall()
        manager.select(turboID)
        await settle()
        manager.cancel()
        await settle()
        XCTAssertEqual(count("delete:\(turboID)"), 0)

        try loader.fail(turboID, CancellationError())
        await settle()

        XCTAssertEqual(Array(loader.log.suffix(2)), ["end:\(turboID)", "delete:\(turboID)"])
    }

    func test_reselect_after_cancel_ignores_stale_success() async throws {
        let (manager, small) = try await readyWithSmall()
        manager.select(turboID)       // A
        await settle()
        manager.cancel()
        manager.select(turboID)       // B
        await settle()
        XCTAssertEqual(count("load:\(turboID)"), 1)

        let stale = try loader.succeed(turboID)
        await settle()

        XCTAssertEqual(manager.activeModel?.id, smallID)
        XCTAssertTrue(manager.transcriptionTarget()?.backend === small)
        XCTAssertFalse(manager.transcriptionTarget()?.backend === stale)
        XCTAssertEqual(
            Array(loader.log.suffix(4)),
            ["load:\(turboID)", "end:\(turboID)", "delete:\(turboID)", "load:\(turboID)"]
        )

        let fresh = try loader.succeed(turboID)
        await settle()

        let target = try XCTUnwrap(manager.transcriptionTarget())
        XCTAssertEqual(target.model.id, turboID)
        XCTAssertTrue(target.backend === fresh)
    }

    func test_reselect_after_cancel_ignores_stale_failure() async throws {
        let (manager, small) = try await readyWithSmall()
        manager.select(turboID)       // A
        await settle()
        manager.cancel()
        manager.select(turboID)       // B
        await settle()

        try loader.fail(turboID, FakeError())
        await settle()

        if case .failed = manager.selection.status(of: turboID) {
            XCTFail("a stale failure must not mark the pending model as failed")
        }
        XCTAssertEqual(persisted, [turboID, smallID, turboID])
        XCTAssertEqual(count("delete:\(turboID)"), 1)
        XCTAssertEqual(manager.selection.pending, turboID)
        XCTAssertEqual(loader.log.last, "load:\(turboID)")
        XCTAssertTrue(manager.transcriptionTarget()?.backend === small)
    }

    func test_boot_failure_with_default_deleted_loads_default() async throws {
        let manager = makeManager()
        manager.bootstrap(selectedID: turboID)
        await settle()
        try loader.fail(turboID, FakeError())
        await settle()

        XCTAssertEqual(count("load:\(smallID)"), 1)
        XCTAssertEqual(persisted, [smallID])
        XCTAssertEqual(manager.selection.pending, smallID)
    }

    // Regression (review 6 r1): offline at boot, the repository request fails
    // before Core ML. The cached files are kept and the cached Small takes over.
    func test_boot_network_failure_keeps_cached_models_and_falls_back_to_default() async throws {
        loader.downloaded = [smallID, turboID]
        let manager = makeManager()
        manager.bootstrap(selectedID: turboID)
        await settle()
        try loader.fail(turboID, URLError(.notConnectedToInternet))
        await settle()
        XCTAssertEqual(manager.selection.pending, smallID)
        try loader.succeed(smallID)
        await settle()

        XCTAssertFalse(loader.log.contains { $0.hasPrefix("delete:") })
        XCTAssertEqual(manager.activeModel?.id, smallID)
        XCTAssertEqual(persisted, [smallID])
        XCTAssertTrue(manager.selection.hasFiles(turboID))
        XCTAssertEqual(manager.selection.status(of: turboID), .failed(URLError(.notConnectedToInternet).localizedDescription))
    }

    func test_boot_network_failure_of_both_cached_models_deletes_nothing() async throws {
        loader.downloaded = [smallID, turboID]
        let manager = makeManager()
        manager.bootstrap(selectedID: turboID)
        await settle()
        try loader.fail(turboID, URLError(.notConnectedToInternet))
        await settle()
        try loader.fail(smallID, URLError(.notConnectedToInternet))
        await settle()

        XCTAssertFalse(loader.log.contains { $0.hasPrefix("delete:") })
        XCTAssertFalse(manager.isReady)
        XCTAssertNil(manager.selection.pending)
        XCTAssertTrue(manager.selection.hasFiles(smallID))
        XCTAssertTrue(manager.selection.hasFiles(turboID))
    }

    // QA F15/K8: the app died loading the Turbo, and the config still picks it.
    // The launch loads the Small instead and the Turbo row shows why.
    func test_boot_after_crash_loads_default_and_shows_failure() async throws {
        loader.downloaded = [smallID, turboID]
        loader.crashed = [turboID]
        let manager = makeManager()
        manager.bootstrap(selectedID: turboID)
        await settle()

        XCTAssertEqual(loader.log, ["load:\(smallID)"])
        XCTAssertEqual(persisted, [smallID])
        try loader.succeed(smallID)
        await settle()
        XCTAssertEqual(manager.activeModel?.id, smallID)
        XCTAssertEqual(manager.selection.status(of: turboID), .failed(SettingsStrings.localModelCrashed))
        XCTAssertTrue(manager.selection.hasFiles(turboID))
    }

    func test_damaged_files_failure_keeps_previous_and_shows_reason() async throws {
        loader.downloaded = [turboID]
        let (manager, small) = try await readyWithSmall()
        manager.select(turboID)
        await settle()
        try loader.fail(turboID, LocalModelLoadError.damagedFiles)
        await settle()

        XCTAssertEqual(manager.selection.status(of: turboID), .failed(SettingsStrings.localModelDamaged))
        XCTAssertEqual(persisted, [turboID, smallID])
        XCTAssertTrue(manager.transcriptionTarget()?.backend === small)
        XCTAssertFalse(loader.log.contains { $0.hasPrefix("delete:") })
    }

    func test_endSession_reaches_loader() {
        makeManager().endSession()
        XCTAssertEqual(loader.log, ["endSession"])
    }

    func test_boot_cancel_with_default_deleted_loads_default() async throws {
        let manager = makeManager()
        manager.bootstrap(selectedID: turboID)
        await settle()
        manager.cancel()
        await settle()

        XCTAssertEqual(count("load:\(smallID)"), 1)
        XCTAssertEqual(persisted, [smallID])
        XCTAssertEqual(manager.selection.pending, smallID)

        try loader.fail(turboID, CancellationError())
        try loader.succeed(smallID)
        await settle()
        XCTAssertEqual(manager.activeModel?.id, smallID)
    }

    func test_delete_calls_loader_only_for_idle_downloaded_model() async throws {
        loader.downloaded = [turboID, parakeetID]
        let (manager, _) = try await readyWithSmall()

        manager.delete(smallID)       // active
        manager.select(parakeetID)
        manager.delete(parakeetID)    // pending
        await settle()
        XCTAssertFalse(loader.log.contains { $0.hasPrefix("delete:") })

        manager.delete(turboID)       // idle and downloaded
        manager.delete(turboID)       // no longer downloaded
        await settle()
        XCTAssertEqual(loader.log.filter { $0.hasPrefix("delete:") }, ["delete:\(turboID)"])
        XCTAssertEqual(manager.selection.status(of: turboID), .notDownloaded)
    }

    func test_vocabulary_dropped_when_model_does_not_support_it() async throws {
        let (parakeetManager, parakeet) = try await ready(with: parakeetID)
        _ = try await LocalTranscriber(manager: parakeetManager)
            .transcribe(audio: oneSecondOfSilence, lang: "pt", vocabulary: "Redis")
        XCTAssertEqual(parakeet.vocabularies, [nil])

        let (smallManager, small) = try await readyWithSmall()
        _ = try await LocalTranscriber(manager: smallManager)
            .transcribe(audio: oneSecondOfSilence, lang: "pt", vocabulary: "Redis")
        XCTAssertEqual(small.vocabularies, ["Redis"])
    }

    func test_switch_during_transcription_keeps_target_consistent() async throws {
        // Parakeet (no vocabulary) active, Small pending: the switch lands mid-transcription.
        let (parakeetManager, parakeet) = try await ready(with: parakeetID)
        parakeetManager.select(smallID)
        await settle()
        parakeet.holdNextTranscription()
        let audio = oneSecondOfSilence
        let first = Task { [parakeetManager] in
            try await LocalTranscriber(manager: parakeetManager).transcribe(audio: audio, lang: "pt", vocabulary: "Redis")
        }
        try await waitUntil { parakeet.isHeld }
        let smallAfterSwitch = try loader.succeed(smallID)
        await settle()
        XCTAssertEqual(parakeetManager.activeModel?.id, smallID)
        parakeet.release()
        _ = try await first.value

        XCTAssertEqual(parakeet.vocabularies, [nil])
        XCTAssertEqual(smallAfterSwitch.vocabularies, [])

        // Small active, Parakeet pending: the Small keeps its vocabulary.
        let (smallManager, small) = try await readyWithSmall()
        smallManager.select(parakeetID)
        await settle()
        small.holdNextTranscription()
        let second = Task { [smallManager] in
            try await LocalTranscriber(manager: smallManager).transcribe(audio: audio, lang: "pt", vocabulary: "Redis")
        }
        try await waitUntil { small.isHeld }
        let parakeetAfterSwitch = try loader.succeed(parakeetID)
        await settle()
        XCTAssertEqual(smallManager.activeModel?.id, parakeetID)
        small.release()
        _ = try await second.value

        XCTAssertEqual(small.vocabularies, ["Redis"])
        XCTAssertEqual(parakeetAfterSwitch.vocabularies, [])
    }
}
