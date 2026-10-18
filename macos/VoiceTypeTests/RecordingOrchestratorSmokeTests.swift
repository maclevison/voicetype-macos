import XCTest
import Core
@testable import VoiceType

@MainActor
final class FakeRecorder: AudioRecorderProtocol {
    var startCalls = 0
    var stopCalls = 0
    var pendingAudio: Data = Data()
    var levelStream: AsyncStream<Float> { AsyncStream { $0.finish() } }

    func start(deviceUID: String?) async throws { startCalls += 1 }
    func stop() async throws -> Data { stopCalls += 1; return pendingAudio }
}

final class RecordingOrchestratorSmokeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // CGEvent.tapCreate(.cgSessionEventTap, …) returns nil under xctest on
        // macOS 14+ because the test runner has no Accessibility grant. Without
        // this bypass, watch() rolls back the registration and simulateKeyDown
        // finds no callback to fire — tests hang on `await iter.next()`.
        HoldDetector.skipTapInstall = true
    }

    override func tearDown() {
        HoldDetector.skipTapInstall = false
        super.tearDown()
    }

    // #50: learn-from-edits is opt-in; off (default) means no post-paste hook → no AX reads.
    @MainActor
    func testLearnHookOnlyWhenOptedIn() {
        let coordinator = RecordingOrchestrator(
            configStore: ConfigStore.inMemory(),
            historyStore: HistoryStore(fileURL: tempHistoryURL()),
            notifier: Notifier(),
            hudController: HUDController(),
            recorder: FakeRecorder(),
            localModels: LocalModelManager(persist: { _ in }),
            editObserver: EditObserver(store: SuggestionStore(fileURL: tempHistoryURL()))
        )
        var cfg = AppConfig()
        XCTAssertNil(coordinator.learnHook(cfg: cfg, mode: .refine), "default is off")
        cfg.learnFromEditsEnabled = true
        XCTAssertNotNil(coordinator.learnHook(cfg: cfg, mode: .refine))
        XCTAssertNotNil(coordinator.learnHook(cfg: cfg, mode: .raw))
        XCTAssertNil(coordinator.learnHook(cfg: cfg, mode: .translate))
        cfg.autoEnterEnabled = true
        XCTAssertNil(coordinator.learnHook(cfg: cfg, mode: .refine))
    }

    @MainActor
    func testHoldShortcutDrivesStateMachineThroughCycle() async throws {
        let store = ConfigStore.inMemory()
        var cfg = try await store.load()
        cfg.shortcuts.refine = "CommandOrControl+Shift+V"
        cfg.translate.enabled = false
        cfg.handsFreeEnabled = false  // quick press/release = push-to-talk cycle
        try await store.save(cfg)

        let stateMachine = AppStateMachine()
        let detector = HoldDetector()
        let manager = ShortcutManager(configStore: store, holdDetector: detector)
        let recorder = FakeRecorder()  // no audio bytes → coordinator silent-resets after stop
        let coordinator = RecordingOrchestrator(
            configStore: store,
            historyStore: HistoryStore(fileURL: tempHistoryURL()),
            notifier: Notifier(),
            hudController: HUDController(),
            recorder: recorder,
            stateMachine: stateMachine,
            shortcutManager: manager,
            localModels: LocalModelManager(persist: { _ in })
        )

        await manager.applyConfig()
        coordinator.startShortcutTasks()
        defer { coordinator.stopShortcutTasks() }

        detector.simulateKeyDown(keycode: Keycode.v, flags: [.maskCommand, .maskShift])
        try await waitFor(state: .recording, on: stateMachine, timeout: 1.0)
        XCTAssertEqual(recorder.startCalls, 1)

        detector.simulateKeyUp(keycode: Keycode.v)
        // Empty audio → coordinator transitions through .processing → .idle silently.
        try await waitFor(state: .idle, on: stateMachine, timeout: 1.0)
        XCTAssertEqual(recorder.stopCalls, 1)
        XCTAssertEqual(coordinator.capturedMode, .refine)
    }

    @MainActor
    func testTranslatePathCapturesTranslateMode() async throws {
        let store = ConfigStore.inMemory()
        var cfg = try await store.load()
        cfg.shortcuts.refine = "CommandOrControl+Shift+V"
        cfg.translate.enabled = true
        cfg.shortcuts.translate = "CommandOrControl+Shift+E"
        cfg.handsFreeEnabled = false
        try await store.save(cfg)

        let stateMachine = AppStateMachine()
        let detector = HoldDetector()
        let manager = ShortcutManager(configStore: store, holdDetector: detector)
        let recorder = FakeRecorder()
        let coordinator = RecordingOrchestrator(
            configStore: store,
            historyStore: HistoryStore(fileURL: tempHistoryURL()),
            notifier: Notifier(),
            hudController: HUDController(),
            recorder: recorder,
            stateMachine: stateMachine,
            shortcutManager: manager,
            localModels: LocalModelManager(persist: { _ in })
        )

        await manager.applyConfig()
        coordinator.startShortcutTasks()
        defer { coordinator.stopShortcutTasks() }

        detector.simulateKeyDown(keycode: Keycode.e, flags: [.maskCommand, .maskShift])
        try await waitFor(state: .recording, on: stateMachine, timeout: 1.0)
        XCTAssertEqual(coordinator.capturedMode, .translate)

        detector.simulateKeyUp(keycode: Keycode.e)
        try await waitFor(state: .idle, on: stateMachine, timeout: 1.0)
    }

    @MainActor
    func testExtraKeyInsideCancelWindowDiscardsRecording() async throws {
        let store = ConfigStore.inMemory()
        var cfg = try await store.load()
        cfg.shortcuts.refine = "CommandOrControl+Shift+V"
        cfg.translate.enabled = false
        try await store.save(cfg)

        let stateMachine = AppStateMachine()
        let detector = HoldDetector()
        let manager = ShortcutManager(configStore: store, holdDetector: detector)
        let recorder = FakeRecorder()
        recorder.pendingAudio = Data(count: 64_000)  // would reach the pipeline if not discarded
        let coordinator = RecordingOrchestrator(
            configStore: store,
            historyStore: HistoryStore(fileURL: tempHistoryURL()),
            notifier: Notifier(),
            hudController: HUDController(),
            recorder: recorder,
            stateMachine: stateMachine,
            shortcutManager: manager,
            localModels: LocalModelManager(persist: { _ in })
        )

        await manager.applyConfig()
        coordinator.startShortcutTasks()
        defer { coordinator.stopShortcutTasks() }

        // Press + extra key back-to-back: the cancel is queued behind the
        // still-starting press and must still discard it.
        detector.simulateKeyDown(keycode: Keycode.v, flags: [.maskCommand, .maskShift])
        detector.simulateKeyDown(keycode: Keycode.a, flags: [.maskCommand, .maskShift])
        let deadline = Date().addingTimeInterval(1.0)
        while recorder.stopCalls == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await waitFor(state: .idle, on: stateMachine, timeout: 1.0)
        XCTAssertEqual(recorder.startCalls, 1)
        XCTAssertEqual(recorder.stopCalls, 1)

        // The chord's release is a no-op — nothing reaches the pipeline.
        detector.simulateKeyUp(keycode: Keycode.v)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(recorder.stopCalls, 1)
        let state = await stateMachine.state
        XCTAssertEqual(state, .idle)
    }

    // Groq-less local dictation is the real setup: only the "groq" engine needs the key.
    @MainActor
    func test_preflight_requires_groq_key_only_for_groq_engine() async {
        let coordinator = RecordingOrchestrator(
            configStore: ConfigStore.inMemory(),
            historyStore: HistoryStore(fileURL: tempHistoryURL()),
            notifier: Notifier(),
            hudController: HUDController(),
            recorder: FakeRecorder(),
            localModels: LocalModelManager(loader: FakeLoader(), persist: { _ in })
        )
        let stateMachine = AppStateMachine()
        var cfg = AppConfig()
        cfg.groq.apiKey = ""

        for engine in ["auto", "local"] {
            cfg.transcriptionEngine = engine
            let passed = await coordinator.preflight(cfg: cfg, requiresTarget: false, stateMachine: stateMachine)
            XCTAssertTrue(passed, engine)
        }
        cfg.transcriptionEngine = "groq"
        let groqWithoutKey = await coordinator.preflight(cfg: cfg, requiresTarget: false, stateMachine: stateMachine)
        XCTAssertFalse(groqWithoutKey)
        cfg.groq.apiKey = "gsk_test"
        let groqWithKey = await coordinator.preflight(cfg: cfg, requiresTarget: false, stateMachine: stateMachine)
        XCTAssertTrue(groqWithKey)
    }

    @MainActor
    func test_default_factory_transcribes_locally_without_groq_key() async throws {
        let loader = FakeLoader()
        loader.downloaded.insert("openai_whisper-small")
        let manager = LocalModelManager(loader: loader, persist: { _ in })
        manager.bootstrap(selectedID: "openai_whisper-small")
        await settle()
        let backend = try loader.succeed("openai_whisper-small", text: "olá mundo")
        await settle()
        XCTAssertTrue(manager.isReady)

        for (calls, engine) in ["auto", "local"].enumerated() {
            let pipeline = RecordingOrchestrator.defaultPipelineFactory(
                "", engine, "auto", "auto", manager, RefineOptions(), { _, _ in }
            )
            let text = try await pipeline.run(audio: oneSecondOfSilence, mode: .raw, lang: "pt", translateTarget: nil)
            XCTAssertEqual(text, "olá mundo", engine)
            XCTAssertEqual(backend.vocabularies.count, calls + 1, engine)
        }
    }

    @MainActor
    func test_default_factory_without_key_surfaces_local_not_ready() async {
        let manager = LocalModelManager(loader: FakeLoader(), persist: { _ in })
        XCTAssertFalse(manager.isReady)
        let pipeline = RecordingOrchestrator.defaultPipelineFactory(
            "", "auto", "auto", "auto", manager, RefineOptions(), { _, _ in }
        )
        do {
            _ = try await pipeline.run(audio: oneSecondOfSilence, mode: .raw, lang: "pt", translateTarget: nil)
            XCTFail("expected LocalError.notReady")
        } catch LocalTranscriber.LocalError.notReady {
            // The factory never tried Groq.
        } catch {
            XCTFail("expected LocalError.notReady, got \(error)")
        }
    }

    private var oneSecondOfSilence: Data {
        WavEncoder.encode(pcmInt16LE: Data(count: 32_000), sampleRate: 16_000, channels: 1)
    }

    /// Lets the manager's main-actor tasks run until they suspend again.
    @MainActor
    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    private func tempHistoryURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VTOrchestratorHistory-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    @MainActor
    private func waitFor(
        state expected: AppStateMachine.State,
        on machine: AppStateMachine,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await machine.state == expected { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let actual = await machine.state
        XCTFail("timed out waiting for \(expected); last state = \(actual)")
    }
}
