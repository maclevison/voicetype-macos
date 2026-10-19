import AppKit
import SwiftUI
import XCTest
import Core
@testable import VoiceType

/// Suspends its callers until `release()`; `isWaiting` tells the test the
/// gated step was reached.
actor TakeGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var isWaiting = false

    func wait() async {
        guard !released else { return }
        isWaiting = true
        await withCheckedContinuation { continuations.append($0) }
    }

    func release() {
        released = true
        isWaiting = false
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

/// `FakeRecorder` whose `start` can be held until `startGate.release()`.
@MainActor
final class GatedRecorder: AudioRecorderProtocol {
    var gatesStart = false
    let startGate = TakeGate()
    var startCalls = 0
    var stopCalls = 0
    var pendingAudio: Data = GatedRecorder.oneSecondOfSpeech
    var levelStream: AsyncStream<Float> { AsyncStream { $0.finish() } }

    func start(deviceUID: String?) async throws {
        startCalls += 1
        if gatesStart { await startGate.wait() }
    }

    func stop() async throws -> Data {
        stopCalls += 1
        return pendingAudio
    }

    static var oneSecondOfSpeech: Data {
        var pcm = Data(capacity: 32_000)
        for _ in 0..<16_000 {
            withUnsafeBytes(of: Int16(1000).littleEndian) { pcm.append(contentsOf: $0) }
        }
        return WavEncoder.encode(pcmInt16LE: pcm, sampleRate: 16_000, channels: 1)
    }
}

@MainActor
final class OnboardingPracticeTests: XCTestCase {

    private enum PipelineVariant { case normal, gated, translateFallsBack }

    private var store: ConfigStore!
    private var historyStore: HistoryStore!
    private var stateMachine: AppStateMachine!
    private var detector: HoldDetector!
    private var manager: ShortcutManager!
    private var recorder: GatedRecorder!
    private var pasteboard: MockPasteboard!
    private var injector: MockEventInjector!
    private var ax: MockAccessibilityWriter!
    private var sink: OnboardingPracticeSink!
    private var coordinator: RecordingOrchestrator!
    private var pipelineGate: TakeGate!
    private var pastes: [OnboardingPaste] = []
    private var generalBackup: PasteboardSnapshot?

    private let otherApp = FocusedField(pid: 4242, identifier: "com.other.editor")
    private let vocabulary = FocusedField(pid: getpid(), identifier: "settings.vocabulary")

    override func setUp() async throws {
        try await super.setUp()
        HoldDetector.skipTapInstall = true
        generalBackup = SystemPasteboard().snapshot()
    }

    override func tearDown() async throws {
        coordinator?.stopShortcutTasks()
        await pipelineGate?.release()
        await recorder?.startGate.release()
        if let generalBackup { SystemPasteboard().restore(generalBackup) }
        HoldDetector.skipTapInstall = false
        try await super.tearDown()
    }

    // MARK: - Harness

    private func field(_ step: OnboardingStep, session: UUID? = nil) -> FocusedField {
        FocusedField(
            pid: getpid(),
            identifier: OnboardingPracticeTicket.fieldIdentifier(session: session ?? sink.session!, step: step)
        )
    }

    private func make(
        step: OnboardingStep = .dictation,
        pipeline variant: PipelineVariant = .normal,
        configure: (inout AppConfig) -> Void = { _ in }
    ) async throws {
        store = ConfigStore.inMemory()
        var cfg = try await store.load()
        cfg.shortcuts.refine = "CommandOrControl+Shift+V"
        cfg.translate.enabled = true
        cfg.shortcuts.translate = "CommandOrControl+Shift+E"
        cfg.handsFreeEnabled = false
        cfg.shortcutCancelWindowMs = 0
        cfg.autoEnterEnabled = false
        cfg.history.enabled = true
        configure(&cfg)
        try await store.save(cfg)

        historyStore = HistoryStore(fileURL: tempHistoryURL())
        stateMachine = AppStateMachine()
        detector = HoldDetector()
        manager = ShortcutManager(configStore: store, holdDetector: detector)
        recorder = GatedRecorder()
        pasteboard = MockPasteboard()
        injector = MockEventInjector()
        ax = MockAccessibilityWriter()
        pipelineGate = TakeGate()

        sink = OnboardingPracticeSink()
        sink.beginSession()
        sink.visibleStep = step
        sink.isKey = true
        listen()

        let own = field(step)
        ax.systemFocus = [own]
        ax.focusAtInsert = own
        ax.tryInsertResult = true

        let gate = pipelineGate!
        let factory: RecordingOrchestrator.PipelineFactory = { _, _, _, _, _, _, _ in
            let translate: Pipeline.TranslateFn = variant == .translateFallsBack
                ? RawFallbackTranslate.make(translate: { _, _ in throw PipelineError.network(message: "offline") })
                : { _, _ in "hello world" }
            return Pipeline(
                transcribe: { _, _, _ in
                    if variant == .gated { await gate.wait() }
                    return "olá mundo"
                },
                refine: { $0 },
                translate: translate
            )
        }

        coordinator = RecordingOrchestrator(
            configStore: store,
            historyStore: historyStore,
            notifier: Notifier(),
            hudController: HUDController(),
            paster: Paster(pasteboard: pasteboard, injector: injector, accessibility: ax,
                           activationDelay: .zero, restoreDelay: .zero),
            recorder: recorder,
            pipelineFactory: factory,
            stateMachine: stateMachine,
            shortcutManager: manager,
            localModels: LocalModelManager(persist: { _ in }),
            practiceSink: sink
        )
        coordinator.frontmostSnapshot = { nil }
        coordinator.ownAppIsFrontmost = { true }

        await manager.applyConfig()
        coordinator.startShortcutTasks()
    }

    private func listen() {
        sink.onPasted = { [weak self] in self?.pastes.append($0) }
    }

    private func pressV() { detector.simulateKeyDown(keycode: Keycode.v, flags: [.maskCommand, .maskShift]) }
    private func releaseV() { detector.simulateKeyUp(keycode: Keycode.v) }

    /// Press + release of V, waiting for the take to finish.
    private func dictate() async throws {
        pressV()
        try await waitFor(state: .recording)
        releaseV()
        try await waitFor(state: .idle)
        await settle()
    }

    /// Press + release of V with the pipeline held; `whileHeld` runs once the
    /// transcription is suspended, before it is released.
    private func dictateHolding(_ whileHeld: () -> Void) async throws {
        pressV()
        try await waitFor(state: .recording)
        releaseV()
        try await waitUntil { await self.pipelineGate.isWaiting }
        whileHeld()
        await pipelineGate.release()
        try await waitFor(state: .idle)
        await settle()
    }

    private func historyCount(_ text: String = "olá mundo") async -> Int {
        await historyStore.list().filter { $0.text == text }.count
    }

    private var generalString: String? { NSPasteboard.general.string(forType: .string) }

    // MARK: - Paste into the onboarding editor

    func testPracticeTakePastesIntoTheOnboardingEditor() async throws {
        try await make()

        try await dictate()

        XCTAssertEqual(ax.lastText, "olá mundo")
        XCTAssertEqual(pastes, [OnboardingPaste(step: .dictation, text: "olá mundo",
                                                take: OnboardingTake(translated: false, handsFree: false))])
        let count = await historyCount()
        XCTAssertEqual(count, 1, "no duplicate history entry")
    }

    func testOtherAppKeepsTheKeyboardPastesNothingButKeepsHistory() async throws {
        try await make()
        ax.systemFocus = [field(.dictation), otherApp]
        ax.focusAtInsert = otherApp

        try await dictate()

        XCTAssertNil(ax.lastText)
        XCTAssertEqual(injector.sendCount, 0)
        XCTAssertTrue(pastes.isEmpty)
        XCTAssertEqual(pasteboard.writes, ["olá mundo"])
        let count = await historyCount()
        XCTAssertEqual(count, 1)
    }

    func testFocusMovedWhileRecorderStartsPastesNothing() async throws {
        try await make()
        recorder.gatesStart = true

        pressV()
        try await waitUntil { await self.recorder.startGate.isWaiting }
        XCTAssertEqual(coordinator.capturedPractice?.step, .dictation)
        // Another editor of the app takes the focus while the mic opens.
        ax.systemFocus = [vocabulary]
        ax.focusAtInsert = vocabulary
        await recorder.startGate.release()
        try await waitFor(state: .recording)
        releaseV()
        try await waitFor(state: .idle)
        await settle()

        XCTAssertNil(ax.lastText)
        XCTAssertEqual(injector.sendCount, 0)
        XCTAssertTrue(pastes.isEmpty)
        XCTAssertEqual(pasteboard.writes, ["olá mundo"])
        let count = await historyCount()
        XCTAssertEqual(count, 1)
    }

    func testFocusMovedDuringTheAXCheckPastesNothing() async throws {
        try await make()
        ax.systemFocus = [field(.dictation), vocabulary]
        ax.focusAtInsert = vocabulary

        try await dictate()

        XCTAssertNil(ax.lastText)
        XCTAssertEqual(injector.sendCount, 0)
        XCTAssertTrue(pastes.isEmpty)
        let count = await historyCount()
        XCTAssertEqual(count, 1)
    }

    func testFocusMovedAndBackStillPastes() async throws {
        try await make()
        recorder.gatesStart = true

        pressV()
        try await waitUntil { await self.recorder.startGate.isWaiting }
        ax.systemFocus = [vocabulary]
        ax.focusAtInsert = vocabulary
        ax.systemFocus = [field(.dictation)]
        ax.focusAtInsert = field(.dictation)
        await recorder.startGate.release()
        try await waitFor(state: .recording)
        releaseV()
        try await waitFor(state: .idle)
        await settle()

        XCTAssertEqual(ax.lastText, "olá mundo")
        XCTAssertEqual(pastes.count, 1)
        let count = await historyCount()
        XCTAssertEqual(count, 1)
    }

    // MARK: - Ticket invalidated before delivery

    func testClosingPracticeBeforeDeliveryPastesNothing() async throws {
        try await make(pipeline: .gated)

        try await dictateHolding { sink.endSession() }

        XCTAssertEqual(ax.tryInsertCalls, 0)
        XCTAssertEqual(injector.sendCount, 0)
        XCTAssertTrue(pastes.isEmpty)
        XCTAssertEqual(generalString, "olá mundo")
        let count = await historyCount()
        XCTAssertEqual(count, 1)
    }

    func testStepChangeBeforeDeliveryPastesNothing() async throws {
        try await make(pipeline: .gated)

        try await dictateHolding { sink.visibleStep = .handsFree }

        XCTAssertEqual(ax.tryInsertCalls, 0)
        XCTAssertEqual(injector.sendCount, 0)
        XCTAssertTrue(pastes.isEmpty)
        let count = await historyCount()
        XCTAssertEqual(count, 1)
    }

    func testReopeningBeforeDeliveryPastesNothing() async throws {
        try await make(pipeline: .gated)

        try await dictateHolding {
            sink.endSession()
            let session = sink.beginSession()
            sink.visibleStep = .dictation
            sink.isKey = true
            listen()
            // The focus is in the new session's editor.
            ax.systemFocus = [field(.dictation, session: session)]
            ax.focusAtInsert = field(.dictation, session: session)
        }

        XCTAssertEqual(ax.tryInsertCalls, 0)
        XCTAssertEqual(injector.sendCount, 0)
        XCTAssertTrue(pastes.isEmpty)
        let count = await historyCount()
        XCTAssertEqual(count, 1)
    }

    func testRefusedDeliveryWithHistoryOffRecordsNothing() async throws {
        try await make(pipeline: .gated) { $0.history.enabled = false }

        try await dictateHolding { sink.endSession() }

        XCTAssertEqual(ax.tryInsertCalls, 0)
        let count = await historyCount()
        XCTAssertEqual(count, 0)
    }

    func testLosingKeyStatusDoesNotInvalidateAValidTicket() async throws {
        try await make(pipeline: .gated)

        try await dictateHolding { sink.isKey = false }

        XCTAssertEqual(ax.lastText, "olá mundo")
        XCTAssertEqual(pastes.count, 1)
        let count = await historyCount()
        XCTAssertEqual(count, 1)
    }

    // MARK: - Paste outcome

    func testFailedPracticePasteMarksNothing() async throws {
        try await make()
        ax.tryInsertResult = false
        injector.shouldThrow = .eventCreationFailed

        try await dictate()

        XCTAssertTrue(pastes.isEmpty)
        let count = await historyCount()
        XCTAssertEqual(count, 1)
    }

    func testClipboardFallbackStillCountsAsPasted() async throws {
        try await make()
        ax.tryInsertResult = false
        pasteboard.readOnWrite = true

        try await dictate()

        XCTAssertEqual(injector.sendCount, 1)
        XCTAssertEqual(pastes.map(\.text), ["olá mundo"])
        let count = await historyCount()
        XCTAssertEqual(count, 1)
    }

    func testTranslatePracticeTakeIsMarkedTranslated() async throws {
        try await make(step: .translation)

        detector.simulateKeyDown(keycode: Keycode.e, flags: [.maskCommand, .maskShift])
        try await waitFor(state: .recording)
        detector.simulateKeyUp(keycode: Keycode.e)
        try await waitFor(state: .idle)
        await settle()

        XCTAssertEqual(ax.lastText, "hello world")
        XCTAssertEqual(pastes.first?.step, .translation)
        XCTAssertEqual(pastes.first?.take.translated, true)
        XCTAssertEqual(pastes.first?.take.translationFellBack, false)
    }

    func testTranslationThatFellBackToRawIsNotMarkedTranslated() async throws {
        try await make(step: .translation, pipeline: .translateFallsBack)

        detector.simulateKeyDown(keycode: Keycode.e, flags: [.maskCommand, .maskShift])
        try await waitFor(state: .recording)
        detector.simulateKeyUp(keycode: Keycode.e)
        try await waitFor(state: .idle)
        await settle()

        XCTAssertEqual(ax.lastText, "olá mundo", "the field gets the raw text, as outside the practice")
        XCTAssertEqual(pastes.first?.take.translated, false)
        XCTAssertEqual(pastes.first?.take.translationFellBack, true)
    }

    func testPracticeTakeCarriesTheLock() async throws {
        try await make(step: .handsFree) {
            $0.handsFreeEnabled = true
            $0.handsFreeUpgradeKey = "Space"
        }

        pressV()
        try await waitFor(state: .recording)
        detector.simulateKeyDown(keycode: Keycode.space)
        try await waitUntil { self.coordinator.capturedLocked }
        releaseV()
        pressV()
        try await waitFor(state: .idle)
        await settle()

        XCTAssertEqual(pastes.first?.step, .handsFree)
        XCTAssertEqual(pastes.first?.take.handsFree, true)
    }

    // MARK: - Who gets a practice target

    func testVoiceTypeInFrontWithoutPracticeStillHasNoTarget() async throws {
        try await make()
        sink.isKey = false

        try await dictate()

        XCTAssertNil(coordinator.capturedPractice)
        XCTAssertEqual(ax.systemFocusCalls, 0)
        XCTAssertEqual(ax.tryInsertCalls, 0)
        XCTAssertEqual(injector.sendCount, 0)
        XCTAssertTrue(pasteboard.events.isEmpty)
        XCTAssertTrue(pastes.isEmpty)
        let count = await historyCount()
        XCTAssertEqual(count, 0)
    }

    func testVoiceNoteNeverRoutesToPractice() async throws {
        try await make { $0.voiceNoteShortcut = "Alt+N" }

        detector.simulateKeyDown(keycode: Keycode.n, flags: [.maskAlternate])
        try await waitFor(state: .recording)
        XCTAssertNil(coordinator.capturedPractice)
        XCTAssertNil(coordinator.capturedTarget)

        recorder.pendingAudio = Data()
        detector.simulateKeyUp(keycode: Keycode.n)
        try await waitFor(state: .idle)
    }

    func testExternalAppInFrontIgnoresPractice() async throws {
        try await make()
        let external = FrontmostAppSnapshot(bundleIdentifier: "com.example.editor", processIdentifier: 4242,
                                            localizedName: "Editor")
        coordinator.frontmostSnapshot = { external }

        pressV()
        try await waitFor(state: .recording)
        XCTAssertNil(coordinator.capturedPractice)
        XCTAssertEqual(coordinator.capturedTarget, external)

        recorder.pendingAudio = Data()
        releaseV()
        try await waitFor(state: .idle)
    }

    func testOtherAppWithoutFrontmostIgnoresPractice() async throws {
        try await make()
        coordinator.ownAppIsFrontmost = { false }

        pressV()
        try await waitFor(state: .recording)
        XCTAssertNil(coordinator.capturedPractice)

        recorder.pendingAudio = Data()
        releaseV()
        try await waitFor(state: .idle)
    }

    // MARK: - Sink

    func testSinkTickets() {
        let sink = OnboardingPracticeSink()
        XCTAssertNil(sink.ticket(), "no session")

        let session = sink.beginSession()
        sink.visibleStep = .dictation
        XCTAssertNil(sink.ticket(), "not the key window")
        sink.isKey = true
        let ticket = sink.ticket()
        XCTAssertEqual(ticket, OnboardingPracticeTicket(session: session, step: .dictation))
        XCTAssertEqual(ticket?.fieldIdentifier, "onboarding.practice.\(session.uuidString).\(OnboardingStep.dictation.rawValue)")

        sink.visibleStep = .voiceNote
        XCTAssertNil(sink.ticket(), "explanation step")

        sink.visibleStep = .dictation
        XCTAssertTrue(sink.isValid(ticket!))
        sink.visibleStep = .handsFree
        XCTAssertFalse(sink.isValid(ticket!), "step changed")
        XCTAssertNotEqual(sink.ticket()?.fieldIdentifier, ticket?.fieldIdentifier, "identifier changes with the step")
        sink.visibleStep = .dictation

        sink.endSession()
        XCTAssertNil(sink.session)
        XCTAssertNil(sink.visibleStep)
        XCTAssertFalse(sink.isKey)
        XCTAssertFalse(sink.isValid(ticket!), "window closed")

        let reopened = sink.beginSession()
        sink.visibleStep = .dictation
        sink.isKey = true
        XCTAssertFalse(sink.isValid(ticket!), "window reopened")
        XCTAssertNotEqual(sink.ticket()?.fieldIdentifier, ticket?.fieldIdentifier, "identifier changes with the session")
        XCTAssertNotEqual(reopened, session)

        // No listener: dropped, never written anywhere.
        sink.onPasted = nil
        sink.pasted(OnboardingPaste(step: .dictation, text: "x", take: OnboardingTake(translated: false, handsFree: false)))
    }

    // MARK: - Waiting

    private func waitFor(state expected: AppStateMachine.State, timeout: TimeInterval = 2.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await stateMachine.state == expected { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let actual = await stateMachine.state
        XCTFail("timed out waiting for \(expected); last state = \(actual)")
    }

    private func waitUntil(timeout: TimeInterval = 2.0, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for condition")
    }

    /// Lets main-actor hops scheduled by the take run before asserting.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func tempHistoryURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VTOnboardingPractice-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }
}

/// The real Accessibility boundary, not `MockAccessibilityWriter`. The system
/// focus (what the `Paster` checks) is the native text view's own AX element,
/// so the identifier must be on that view; SwiftUI's `TextEditor` puts it only
/// on a node of its own accessibility tree (an AX hit test or tree walk finds
/// it there, the focus does not). The end-to-end check through the system
/// focus needs a key window, which a test host does not get.
@MainActor
final class PracticeTextEditorAccessibilityTests: XCTestCase {

    func testNativeTextElementCarriesTheTicketIdentifierAndAnAXWriteReachesTheBinding() throws {
        var text = ""
        let identifier = OnboardingPracticeTicket(session: UUID(), step: .dictation).fieldIdentifier
        let editor = PracticeTextEditor(
            text: Binding(get: { text }, set: { text = $0 }),
            identifier: identifier,
            focusRequest: 0
        )
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 110),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = NSHostingView(rootView: editor.frame(width: 320, height: 110))
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let textView = try XCTUnwrap(Self.textView(in: window.contentView))
        XCTAssertEqual(textView.accessibilityIdentifier(), identifier)

        // An AX write into the field reaches the binding the step is confirmed against.
        let frame = window.convertToScreen(textView.convert(textView.bounds, to: nil))
        let primaryHeight = NSScreen.screens[0].frame.maxY
        var hit: AXUIElement?
        XCTAssertEqual(AXUIElementCopyElementAtPosition(AXUIElementCreateApplication(getpid()),
                                                        Float(frame.midX), Float(primaryHeight - frame.midY), &hit), .success)
        let element = try XCTUnwrap(hit)
        XCTAssertEqual(AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, "olá" as CFTypeRef), .success)
        XCTAssertEqual(text, "olá")
    }

    private static func textView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let textView = view as? NSTextView { return textView }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
}
