import AppKit
import XCTest
@testable import VoiceType

final class MockPasteboard: PasteboardProtocol, @unchecked Sendable {
    enum Event: Equatable {
        case snapshot
        case writeString(String)
        case writeLazyString(String)
        case restore(PasteboardSnapshot)
    }

    var stored: PasteboardSnapshot = PasteboardSnapshot(items: [])
    var events: [Event] = []
    var writes: [String] = []
    var changeCountValue = 0
    // Simulates a consumer reading the promised string right away.
    var readOnWrite = true
    var lastPayload: LazyPasteboardString?

    func snapshot() -> PasteboardSnapshot {
        events.append(.snapshot)
        return stored
    }

    func writeString(_ text: String) {
        events.append(.writeString(text))
        writes.append(text)
        // Mirror SystemPasteboard semantic: clear + setString replaces contents.
        let data = Data(text.utf8)
        stored = PasteboardSnapshot(items: [[NSPasteboard.PasteboardType.string.rawValue: data]])
        changeCountValue += 1
    }

    func writeLazyString(_ payload: LazyPasteboardString) -> Int? {
        events.append(.writeLazyString(payload.text))
        writes.append(payload.text)
        lastPayload = payload
        stored = PasteboardSnapshot(items: [[NSPasteboard.PasteboardType.string.rawValue: Data(payload.text.utf8)]])
        changeCountValue += 1
        if readOnWrite { simulateRead() }
        return changeCountValue
    }

    func simulateRead() {
        lastPayload?.pasteboard(nil, item: NSPasteboardItem(), provideDataForType: .string)
    }

    func changeCount() -> Int {
        changeCountValue
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        events.append(.restore(snapshot))
        stored = snapshot
        changeCountValue += 1
    }

    var didRestore: Bool {
        events.contains { if case .restore = $0 { return true } else { return false } }
    }
}

final class MockEventInjector: EventInjectorProtocol, @unchecked Sendable {
    var sendCount = 0
    var sendReturnCount = 0
    var shouldThrow: EventInjectorError?
    var shouldThrowOnReturn: EventInjectorError?
    func sendCommandV() throws {
        if let shouldThrow { throw shouldThrow }
        sendCount += 1
    }
    func sendReturn() throws {
        if let shouldThrowOnReturn { throw shouldThrowOnReturn }
        sendReturnCount += 1
    }
}

final class MockAccessibilityWriter: AccessibilityWriterProtocol, @unchecked Sendable {
    var tryInsertResult: Bool = false
    var tryInsertCalls: Int = 0
    var lastText: String?
    var hasFocusedTextFieldResult: Bool = false
    var hasFocusedTextFieldCalls: Int = 0
    var prepareFocusResult: FocusEditability = .unknown
    var prepareFocusTargets: [FrontmostAppSnapshot] = []
    // System focus seen by each `systemFocusedField` call, in order; the last
    // value repeats once the queue runs out.
    var systemFocus: [FocusedField?] = []
    var systemFocusCalls = 0
    // The system's focused text element at `tryInsert` time.
    var focusAtInsert: FocusedField?
    // `Thread.isMainThread` at each `tryInsert`/`systemFocusedField` call.
    var calledOnMain: [Bool] = []

    func tryInsert(text: String, required: FocusedField?) -> Bool {
        tryInsertCalls += 1
        calledOnMain.append(Thread.isMainThread)
        if let required, focusAtInsert != required { return false }
        lastText = text
        return tryInsertResult
    }

    func systemFocusedField() -> FocusedField? {
        defer { systemFocusCalls += 1 }
        calledOnMain.append(Thread.isMainThread)
        guard !systemFocus.isEmpty else { return nil }
        return systemFocus[min(systemFocusCalls, systemFocus.count - 1)]
    }

    func hasFocusedTextField() -> Bool {
        hasFocusedTextFieldCalls += 1
        return hasFocusedTextFieldResult
    }

    func prepareFocus(target snapshot: FrontmostAppSnapshot) -> FocusEditability {
        prepareFocusTargets.append(snapshot)
        return prepareFocusResult
    }
}

// Deterministic stand-in for Task.sleep: records each requested duration and
// lets a test react to the n-th sleep (simulate a late read, a user copy…).
final class RecordingSleeper: @unchecked Sendable {
    var sleeps: [Duration] = []
    var onSleep: ((Int, Duration) -> Void)?

    var sleep: @Sendable (Duration) async -> Void {
        { [self] duration in
            sleeps.append(duration)
            onSleep?(sleeps.count, duration)
        }
    }
}

final class PasterTests: XCTestCase {

    private func selfTarget() -> FrontmostAppSnapshot {
        FrontmostAppSnapshot(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            localizedName: "self"
        )
    }

    func testAccessibilitySuccessSkipsClipboardAndPaste() async throws {
        let pb = MockPasteboard()
        let injector = MockEventInjector()
        let ax = MockAccessibilityWriter()
        ax.tryInsertResult = true

        let paster = Paster(
            pasteboard: pb,
            injector: injector,
            accessibility: ax,
            activationDelay: .milliseconds(0),
            restoreDelay: .milliseconds(0)
        )

        try await paster.paste(text: "olá mundo", target: selfTarget())

        XCTAssertEqual(ax.tryInsertCalls, 1)
        XCTAssertEqual(ax.lastText, "olá mundo")
        XCTAssertEqual(injector.sendCount, 0)
        XCTAssertTrue(pb.events.isEmpty, "AX success path must not touch the clipboard")
    }

    func testAccessibilityFailureFallsBackToClipboardPaste() async throws {
        let pb = MockPasteboard()
        let originalSnapshot = PasteboardSnapshot(items: [
            [NSPasteboard.PasteboardType.string.rawValue: Data("previous clipboard".utf8)]
        ])
        pb.stored = originalSnapshot

        let injector = MockEventInjector()
        let ax = MockAccessibilityWriter()
        ax.tryInsertResult = false

        let paster = Paster(
            pasteboard: pb,
            injector: injector,
            accessibility: ax,
            activationDelay: .milliseconds(0),
            restoreDelay: .milliseconds(0)
        )

        try await paster.paste(text: "olá mundo", target: selfTarget())

        XCTAssertEqual(ax.tryInsertCalls, 1)
        XCTAssertEqual(injector.sendCount, 1)
        XCTAssertEqual(pb.writes, ["olá mundo"])

        XCTAssertEqual(pb.events.count, 3)
        XCTAssertEqual(pb.events.first, .snapshot)
        XCTAssertEqual(pb.events[1], .writeLazyString("olá mundo"))
        XCTAssertEqual(pb.events.last, .restore(originalSnapshot))
    }

    func testPasteWithMissingTargetThrows() async throws {
        let ax = MockAccessibilityWriter()
        let paster = Paster(
            pasteboard: MockPasteboard(),
            injector: MockEventInjector(),
            accessibility: ax
        )
        let snapshot = FrontmostAppSnapshot(
            bundleIdentifier: "com.example.gone",
            processIdentifier: 99999,
            localizedName: "Gone"
        )
        do {
            try await paster.paste(text: "x", target: snapshot)
            XCTFail("expected throw")
        } catch let error as PasterError {
            XCTAssertEqual(error, .targetAppNotRunning)
        }
        XCTAssertEqual(ax.tryInsertCalls, 0, "AX must not be attempted before target activation")
    }

    func testEventInjectionFailureSurfacesAndRestoresClipboard() async throws {
        let pb = MockPasteboard()
        let originalSnapshot = PasteboardSnapshot(items: [
            [NSPasteboard.PasteboardType.string.rawValue: Data("preserved".utf8)]
        ])
        pb.stored = originalSnapshot

        let injector = MockEventInjector()
        injector.shouldThrow = .eventCreationFailed
        let ax = MockAccessibilityWriter()
        ax.tryInsertResult = false

        let paster = Paster(
            pasteboard: pb,
            injector: injector,
            accessibility: ax,
            activationDelay: .milliseconds(0),
            restoreDelay: .milliseconds(0)
        )

        do {
            try await paster.paste(text: "x", target: selfTarget())
            XCTFail("expected throw")
        } catch let error as PasterError {
            XCTAssertEqual(error, .eventInjectionFailed)
        }

        XCTAssertEqual(pb.stored, originalSnapshot, "clipboard must be restored even when Cmd+V fails")
    }

    // MARK: - auto-Enter

    func testAutoEnterFiresAfterAccessibilitySuccessWhenTextFieldFocused() async throws {
        let pb = MockPasteboard()
        let injector = MockEventInjector()
        let ax = MockAccessibilityWriter()
        ax.tryInsertResult = true
        ax.hasFocusedTextFieldResult = true

        let paster = Paster(
            pasteboard: pb,
            injector: injector,
            accessibility: ax,
            activationDelay: .milliseconds(0),
            restoreDelay: .milliseconds(0),
            autoEnterDelay: .milliseconds(0)
        )

        try await paster.paste(text: "olá", target: selfTarget(), autoEnter: true)

        XCTAssertEqual(injector.sendCount, 0)
        XCTAssertEqual(injector.sendReturnCount, 1)
    }

    func testAutoEnterFiresAfterClipboardFallbackWhenTextFieldFocused() async throws {
        let pb = MockPasteboard()
        let injector = MockEventInjector()
        let ax = MockAccessibilityWriter()
        ax.tryInsertResult = false
        ax.hasFocusedTextFieldResult = true

        let paster = Paster(
            pasteboard: pb,
            injector: injector,
            accessibility: ax,
            activationDelay: .milliseconds(0),
            restoreDelay: .milliseconds(0),
            autoEnterDelay: .milliseconds(0)
        )

        try await paster.paste(text: "olá", target: selfTarget(), autoEnter: true)

        XCTAssertEqual(injector.sendCount, 1)
        XCTAssertEqual(injector.sendReturnCount, 1)
    }

    func testAutoEnterDoesNotFireWhenNoTextFieldFocused() async throws {
        let pb = MockPasteboard()
        let injector = MockEventInjector()
        let ax = MockAccessibilityWriter()
        ax.tryInsertResult = false
        ax.hasFocusedTextFieldResult = false

        let paster = Paster(
            pasteboard: pb,
            injector: injector,
            accessibility: ax,
            activationDelay: .milliseconds(0),
            restoreDelay: .milliseconds(0),
            autoEnterDelay: .milliseconds(0)
        )

        try await paster.paste(text: "olá", target: selfTarget(), autoEnter: true)

        XCTAssertEqual(injector.sendCount, 1)
        XCTAssertEqual(injector.sendReturnCount, 0)
    }

    func testAutoEnterDisabledNeverSendsReturn() async throws {
        // AX-success path
        let pbAX = MockPasteboard()
        let injectorAX = MockEventInjector()
        let axAX = MockAccessibilityWriter()
        axAX.tryInsertResult = true
        axAX.hasFocusedTextFieldResult = true
        let pasterAX = Paster(
            pasteboard: pbAX,
            injector: injectorAX,
            accessibility: axAX,
            activationDelay: .milliseconds(0),
            restoreDelay: .milliseconds(0),
            autoEnterDelay: .milliseconds(0)
        )
        try await pasterAX.paste(text: "olá", target: selfTarget(), autoEnter: false)
        XCTAssertEqual(injectorAX.sendReturnCount, 0)
        XCTAssertEqual(axAX.hasFocusedTextFieldCalls, 0, "autoEnter=false must not probe focus")

        // Fallback path
        let pbCV = MockPasteboard()
        let injectorCV = MockEventInjector()
        let axCV = MockAccessibilityWriter()
        axCV.tryInsertResult = false
        axCV.hasFocusedTextFieldResult = true
        let pasterCV = Paster(
            pasteboard: pbCV,
            injector: injectorCV,
            accessibility: axCV,
            activationDelay: .milliseconds(0),
            restoreDelay: .milliseconds(0),
            autoEnterDelay: .milliseconds(0)
        )
        try await pasterCV.paste(text: "olá", target: selfTarget(), autoEnter: false)
        XCTAssertEqual(injectorCV.sendReturnCount, 0)
    }

    // MARK: - editability / refocus

    func testConfirmedNonEditableFocusSkipsPasteAndLeavesTextOnClipboard() async throws {
        let pb = MockPasteboard()
        pb.stored = PasteboardSnapshot(items: [
            [NSPasteboard.PasteboardType.string.rawValue: Data("previous".utf8)]
        ])
        let injector = MockEventInjector()
        let ax = MockAccessibilityWriter()
        ax.prepareFocusResult = .notEditable
        ax.tryInsertResult = true

        let paster = Paster(
            pasteboard: pb,
            injector: injector,
            accessibility: ax,
            activationDelay: .milliseconds(0),
            restoreDelay: .milliseconds(0)
        )

        do {
            try await paster.paste(text: "olá", target: selfTarget(), autoEnter: true)
            XCTFail("expected throw")
        } catch let error as PasterError {
            XCTAssertEqual(error, .noEditableField)
        }

        XCTAssertEqual(ax.tryInsertCalls, 0, "no AX write into a non-editable focus")
        XCTAssertEqual(injector.sendCount, 0, "no Cmd+V into a non-editable focus")
        XCTAssertEqual(injector.sendReturnCount, 0)
        XCTAssertEqual(pb.writes, ["olá"], "text must stay on the clipboard for manual paste")
        XCTAssertFalse(pb.didRestore)
    }

    func testUnknownEditabilityKeepsClipboardFallback() async throws {
        let pb = MockPasteboard()
        let injector = MockEventInjector()
        let ax = MockAccessibilityWriter()
        ax.prepareFocusResult = .unknown
        ax.tryInsertResult = false

        let paster = Paster(
            pasteboard: pb,
            injector: injector,
            accessibility: ax,
            activationDelay: .milliseconds(0),
            restoreDelay: .milliseconds(0)
        )

        try await paster.paste(text: "olá", target: selfTarget())

        XCTAssertEqual(ax.tryInsertCalls, 1)
        XCTAssertEqual(injector.sendCount, 1)
    }

    func testPrepareFocusReceivesCapturedTarget() async throws {
        let ax = MockAccessibilityWriter()
        ax.tryInsertResult = true
        let element = AXElementRef(AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier))
        let target = FrontmostAppSnapshot(
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            localizedName: "self",
            focusedElement: element
        )
        let paster = Paster(
            pasteboard: MockPasteboard(),
            injector: MockEventInjector(),
            accessibility: ax,
            activationDelay: .milliseconds(0),
            restoreDelay: .milliseconds(0)
        )

        try await paster.paste(text: "olá", target: target)

        XCTAssertEqual(ax.prepareFocusTargets.first?.focusedElement, element)
    }

    func testEditabilityClassification() {
        typealias W = SystemAccessibilityWriter
        // Settable text wins regardless of role or app.
        XCTAssertEqual(W.classify(role: "AXGroup", isTextSettable: true, bundleIdentifier: "x"), .editable)
        XCTAssertEqual(W.classify(role: "AXTextField", isTextSettable: true, bundleIdentifier: "com.apple.finder"), .editable)
        // Text role with read-only value (Terminal) → fail-open.
        XCTAssertEqual(W.classify(role: "AXTextArea", isTextSettable: false, bundleIdentifier: "com.apple.Terminal"), .unknown)
        // No AX answer outside Finder → fail-open.
        XCTAssertEqual(W.classify(role: nil, isTextSettable: false, bundleIdentifier: "com.tinyspeck.slackmacgap"), .unknown)
        XCTAssertEqual(W.classify(role: "AXGroup", isTextSettable: false, bundleIdentifier: "com.microsoft.VSCode"), .unknown)
        // Finder/desktop and known non-text roles → confirmed non-editable.
        XCTAssertEqual(W.classify(role: nil, isTextSettable: false, bundleIdentifier: "com.apple.finder"), .notEditable)
        XCTAssertEqual(W.classify(role: "AXScrollArea", isTextSettable: false, bundleIdentifier: "com.apple.finder"), .notEditable)
        XCTAssertEqual(W.classify(role: "AXOutline", isTextSettable: false, bundleIdentifier: "com.apple.mail"), .notEditable)
    }

    func testStaleElementEditabilityDoesNotCrash() {
        // pid 99999 does not exist: every AX call on it fails cleanly.
        let stale = AXUIElementCreateApplication(99999)
        XCTAssertEqual(SystemAccessibilityWriter.editability(of: stale, bundleIdentifier: "x"), .unknown)
        let target = FrontmostAppSnapshot(
            bundleIdentifier: "x",
            processIdentifier: 99999,
            localizedName: "gone",
            focusedElement: AXElementRef(stale)
        )
        XCTAssertEqual(SystemAccessibilityWriter().prepareFocus(target: target), .unknown)
    }

    // MARK: - required field (onboarding practice)

    private let practiceID = "onboarding.practice.test.1"
    private var own: FocusedField { FocusedField(pid: getpid(), identifier: practiceID) }
    private let otherApp = FocusedField(pid: 4242, identifier: "com.other.editor")
    private let vocabulary = FocusedField(pid: getpid(), identifier: "settings.vocabulary")

    private func requiredFieldPaster(_ pb: MockPasteboard, _ injector: MockEventInjector, _ ax: MockAccessibilityWriter) -> Paster {
        Paster(
            pasteboard: pb,
            injector: injector,
            accessibility: ax,
            activationDelay: .zero,
            restoreDelay: .zero
        )
    }

    func testRequiredFieldMismatchThrowsWithoutInsertOrPaste() async throws {
        let pb = MockPasteboard()
        let injector = MockEventInjector()
        let ax = MockAccessibilityWriter()
        ax.systemFocus = [vocabulary]
        ax.tryInsertResult = true

        do {
            try await requiredFieldPaster(pb, injector, ax).paste(text: "olá", target: selfTarget(), requiredField: own)
            XCTFail("expected throw")
        } catch let error as PasterError {
            XCTAssertEqual(error, .focusMoved)
        }

        XCTAssertEqual(ax.tryInsertCalls, 0)
        XCTAssertEqual(injector.sendCount, 0)
        XCTAssertTrue(ax.prepareFocusTargets.isEmpty, "a practice paste never refocuses")
        XCTAssertEqual(pb.writes, ["olá"])
    }

    func testOtherAppKeepingTheKeyboardBlocksCmdV() async throws {
        let pb = MockPasteboard()
        let injector = MockEventInjector()
        let ax = MockAccessibilityWriter()
        // The first check passes, but activation did not take the other app
        // out of the front by the time of the write.
        ax.systemFocus = [own, otherApp]
        ax.focusAtInsert = otherApp
        ax.tryInsertResult = true

        do {
            try await requiredFieldPaster(pb, injector, ax).paste(text: "olá", target: selfTarget(), requiredField: own)
            XCTFail("expected throw")
        } catch let error as PasterError {
            XCTAssertEqual(error, .focusMoved)
        }

        XCTAssertNil(ax.lastText)
        XCTAssertEqual(injector.sendCount, 0)
        XCTAssertEqual(pb.writes, ["olá"])
    }

    func testOtherAppInFrontFromTheStartBlocksEverything() async throws {
        let pb = MockPasteboard()
        let injector = MockEventInjector()
        let ax = MockAccessibilityWriter()
        ax.systemFocus = [otherApp]
        ax.focusAtInsert = otherApp
        ax.tryInsertResult = true

        do {
            try await requiredFieldPaster(pb, injector, ax).paste(text: "olá", target: selfTarget(), requiredField: own)
            XCTFail("expected throw")
        } catch let error as PasterError {
            XCTAssertEqual(error, .focusMoved)
        }

        XCTAssertNil(ax.lastText)
        XCTAssertEqual(ax.tryInsertCalls, 0)
        XCTAssertEqual(injector.sendCount, 0)
    }

    func testFocusChangeDuringTheCheckNeverReachesTheOtherEditor() async throws {
        let pb = MockPasteboard()
        let injector = MockEventInjector()
        let ax = MockAccessibilityWriter()
        ax.systemFocus = [own, vocabulary]
        ax.focusAtInsert = vocabulary
        ax.tryInsertResult = true

        do {
            try await requiredFieldPaster(pb, injector, ax).paste(text: "olá", target: selfTarget(), requiredField: own)
            XCTFail("expected throw")
        } catch let error as PasterError {
            XCTAssertEqual(error, .focusMoved)
        }

        XCTAssertNil(ax.lastText)
        XCTAssertEqual(injector.sendCount, 0)
    }

    func testMatchingFieldInsertsWithoutPrepareFocus() async throws {
        let pb = MockPasteboard()
        let injector = MockEventInjector()
        let ax = MockAccessibilityWriter()
        ax.systemFocus = [own]
        ax.focusAtInsert = own
        ax.tryInsertResult = true

        try await requiredFieldPaster(pb, injector, ax).paste(text: "olá", target: selfTarget(), requiredField: own)

        XCTAssertEqual(ax.lastText, "olá")
        XCTAssertEqual(injector.sendCount, 0)
        XCTAssertTrue(ax.prepareFocusTargets.isEmpty)
        XCTAssertTrue(pb.events.isEmpty)
    }

    func testMatchingFieldFallsBackToCmdVAfterRecheck() async throws {
        let pb = MockPasteboard()
        let injector = MockEventInjector()
        let ax = MockAccessibilityWriter()
        ax.systemFocus = [own, own]
        ax.focusAtInsert = own
        ax.tryInsertResult = false

        try await requiredFieldPaster(pb, injector, ax).paste(text: "olá", target: selfTarget(), requiredField: own)

        XCTAssertEqual(ax.systemFocusCalls, 2, "checked again right before Cmd+V")
        XCTAssertEqual(injector.sendCount, 1)
        XCTAssertTrue(ax.prepareFocusTargets.isEmpty)
    }

    // The required field is VoiceType's own editor: AX on it runs AppKit on
    // the calling thread, so every check and the write go through the main one.
    func testRequiredFieldAccessibilityRunsOnTheMainThread() async throws {
        let pb = MockPasteboard()
        let injector = MockEventInjector()
        let ax = MockAccessibilityWriter()
        ax.systemFocus = [own, own]
        ax.focusAtInsert = own
        ax.tryInsertResult = false

        try await requiredFieldPaster(pb, injector, ax).paste(text: "olá", target: selfTarget(), requiredField: own)

        XCTAssertEqual(ax.calledOnMain, [true, true, true])
    }

    // MARK: - lazy pasteboard fallback

    private func fallbackPaster(_ pb: MockPasteboard, _ injector: MockEventInjector, _ sleeper: RecordingSleeper) -> Paster {
        let ax = MockAccessibilityWriter()
        ax.tryInsertResult = false
        return Paster(
            pasteboard: pb,
            injector: injector,
            accessibility: ax,
            activationDelay: .milliseconds(80),
            restoreDelay: .milliseconds(500),
            autoEnterDelay: .milliseconds(50),
            readTimeout: .seconds(1),
            readPollInterval: .milliseconds(20),
            sleep: sleeper.sleep
        )
    }

    func testLateReadRestoresClipboardRestoreDelayAfterTheRead() async throws {
        let pb = MockPasteboard()
        let original = PasteboardSnapshot(items: [[NSPasteboard.PasteboardType.string.rawValue: Data("previous".utf8)]])
        pb.stored = original
        pb.readOnWrite = false
        let sleeper = RecordingSleeper()
        // sleep #1 = activation; the app reads during the 3rd poll.
        sleeper.onSleep = { n, _ in if n == 4 { pb.simulateRead() } }

        try await fallbackPaster(pb, MockEventInjector(), sleeper).paste(text: "olá", target: selfTarget())

        XCTAssertEqual(sleeper.sleeps, [
            .milliseconds(80),
            .milliseconds(20), .milliseconds(20), .milliseconds(20),
            .milliseconds(500)
        ])
        XCTAssertEqual(pb.events.last, .restore(original))
        XCTAssertEqual(pb.stored, original)
    }

    func testNoReadWithinTimeoutThrowsAndKeepsTextOnClipboard() async throws {
        let pb = MockPasteboard()
        pb.stored = PasteboardSnapshot(items: [[NSPasteboard.PasteboardType.string.rawValue: Data("previous".utf8)]])
        pb.readOnWrite = false
        let injector = MockEventInjector()
        let sleeper = RecordingSleeper()

        do {
            try await fallbackPaster(pb, injector, sleeper).paste(text: "olá", target: selfTarget(), autoEnter: true)
            XCTFail("expected throw")
        } catch let error as PasterError {
            XCTAssertEqual(error, .pasteNotConsumed)
        }

        XCTAssertEqual(injector.sendCount, 1)
        XCTAssertEqual(injector.sendReturnCount, 0, "no auto-Enter after a likely failed paste")
        XCTAssertEqual(sleeper.sleeps.filter { $0 == .milliseconds(20) }.count, 50, "1 s of 20 ms polls")
        XCTAssertFalse(pb.didRestore)
        XCTAssertEqual(pb.events.last, .writeString("olá"), "promise swapped for concrete text")
    }

    func testUserCopyDuringPasteIsNotClobberedByRestore() async throws {
        let pb = MockPasteboard()
        pb.stored = PasteboardSnapshot(items: [[NSPasteboard.PasteboardType.string.rawValue: Data("previous".utf8)]])
        let sleeper = RecordingSleeper()
        // The user copies something while we wait to restore.
        sleeper.onSleep = { _, d in if d == .milliseconds(500) { pb.changeCountValue += 1 } }

        try await fallbackPaster(pb, MockEventInjector(), sleeper).paste(text: "olá", target: selfTarget())

        XCTAssertFalse(pb.didRestore)
    }

    func testNoReadButUserCopiedDoesNotOverwriteUserClipboard() async throws {
        let pb = MockPasteboard()
        pb.readOnWrite = false
        let sleeper = RecordingSleeper()
        sleeper.onSleep = { n, _ in if n == 2 { pb.changeCountValue += 1 } }

        do {
            try await fallbackPaster(pb, MockEventInjector(), sleeper).paste(text: "olá", target: selfTarget())
            XCTFail("expected throw")
        } catch let error as PasterError {
            XCTAssertEqual(error, .pasteNotConsumed)
        }

        XCTAssertFalse(pb.events.contains(.writeString("olá")))
        XCTAssertFalse(pb.didRestore)
    }

    func testLazyPasteboardStringFlagsReadOnProvide() {
        let payload = LazyPasteboardString("olá")
        XCTAssertFalse(payload.wasRead)
        let item = NSPasteboardItem()
        payload.pasteboard(nil, item: item, provideDataForType: .string)
        XCTAssertTrue(payload.wasRead)
        XCTAssertEqual(item.string(forType: .string), "olá")
    }

    func testSystemPasteboardLazyWriteRendersOnReadAndIsConcealed() {
        let pb = SystemPasteboard()
        let prior = pb.snapshot()
        defer { pb.restore(prior) }

        let payload = LazyPasteboardString("lazy olá")
        let written = pb.writeLazyString(payload)
        XCTAssertEqual(written, pb.changeCount())
        XCTAssertFalse(payload.wasRead, "nothing rendered until someone asks")

        let general = NSPasteboard.general
        XCTAssertTrue(general.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) ?? false)
        XCTAssertEqual(general.string(forType: .string), "lazy olá")
        XCTAssertTrue(payload.wasRead)
        XCTAssertEqual(pb.changeCount(), written, "fulfilling the promise must not bump changeCount")
    }

    func testSnapshotRestoreRoundTripsMultiTypeItems() {
        let pb = SystemPasteboard()
        let pasteboard = NSPasteboard.general
        let priorSnapshot = pb.snapshot()
        defer { pb.restore(priorSnapshot) }

        let rtfData = Data("{\\rtf1\\ansi hello}".utf8)
        let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        let item1 = NSPasteboardItem()
        item1.setString("hello world", forType: .string)
        item1.setData(rtfData, forType: .rtf)

        let item2 = NSPasteboardItem()
        item2.setData(pngData, forType: .png)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item1, item2]))

        let captured = pb.snapshot()
        XCTAssertEqual(captured.items.count, 2)

        // Mutate the pasteboard, then restore from the snapshot.
        pb.writeString("clobber")
        XCTAssertEqual(pasteboard.string(forType: .string), "clobber")

        pb.restore(captured)
        let restored = pb.snapshot()

        XCTAssertEqual(restored.items.count, 2, "restore must rebuild both items")
        let stringValues = restored.items.compactMap { $0[NSPasteboard.PasteboardType.string.rawValue] }
        XCTAssertEqual(stringValues, [Data("hello world".utf8)])

        let rtfValues = restored.items.compactMap { $0[NSPasteboard.PasteboardType.rtf.rawValue] }
        XCTAssertEqual(rtfValues, [rtfData])

        let pngValues = restored.items.compactMap { $0[NSPasteboard.PasteboardType.png.rawValue] }
        XCTAssertEqual(pngValues, [pngData])
    }
}

final class PasteKeyCodeTests: XCTestCase {

    private func table(_ map: [CGKeyCode: String]) -> (CGKeyCode) -> String? {
        { map[$0] }
    }

    func testANSIAndABNT2LayoutsResolveTo0x09() {
        XCTAssertEqual(PasteKeyCode.resolve(for: "v", translate: table([0x08: "c", 0x09: "v"])), 0x09)
    }

    func testDvorakResolvesToTheKeyThatTypesV() {
        // Dvorak: the ANSI-V position types "k"; "v" sits on the ANSI "." key.
        XCTAssertEqual(PasteKeyCode.resolve(for: "v", translate: table([0x09: "k", 0x2F: "v"])), 0x2F)
    }

    func testLowestMatchingKeyCodeWins() {
        XCTAssertEqual(PasteKeyCode.resolve(for: "v", translate: table([0x2F: "v", 0x09: "v"])), 0x09)
    }

    func testResolutionFailureFallsBackToANSI() {
        XCTAssertEqual(PasteKeyCode.resolve(for: "v", translate: table([0x09: "м"])), PasteKeyCode.ansiV)
        XCTAssertEqual(PasteKeyCode.resolve(for: "v", translate: nil), PasteKeyCode.ansiV)
    }

    @MainActor
    func testRefreshWithTheRealLayoutYieldsAValidKeyCode() {
        PasteKeyCode.refresh()
        XCTAssertLessThan(PasteKeyCode.v, 128)
    }
}
