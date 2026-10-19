import AppKit
import Foundation

public enum PasterError: Error, Equatable {
    case targetAppNotRunning
    case targetActivationFailed
    case eventInjectionFailed
    case accessibilityMissing
    // Focus confirmed non-editable (Finder, desktop, a list…): Cmd+V skipped,
    // the text is left on the clipboard so the user can paste it by hand.
    case noEditableField
    // Clipboard+Cmd+V fallback: the pasteboard rejected our write.
    case clipboardWriteFailed
    // Clipboard+Cmd+V fallback: no app read the clipboard within the timeout,
    // so the paste most likely did not land. Text is left on the clipboard.
    case pasteNotConsumed
    // `requiredField` given, but the system focus is not that editor (another
    // field, or another app kept the keyboard): nothing inserted nor pasted,
    // the text is left on the clipboard.
    case focusMoved
}

public actor Paster {
    private let pasteboard: PasteboardProtocol
    private let injector: EventInjectorProtocol
    private let accessibility: AccessibilityWriterProtocol
    private let activationDelay: Duration
    private let restoreDelay: Duration
    private let autoEnterDelay: Duration
    private let readTimeout: Duration
    private let readPollInterval: Duration
    // Injectable clock for the timing logic (tests drive it deterministically).
    private let sleep: @Sendable (Duration) async -> Void

    public init(
        pasteboard: PasteboardProtocol = SystemPasteboard(),
        injector: EventInjectorProtocol = SystemEventInjector(),
        accessibility: AccessibilityWriterProtocol = SystemAccessibilityWriter(),
        activationDelay: Duration = .milliseconds(80),
        restoreDelay: Duration = .milliseconds(500),
        autoEnterDelay: Duration = .milliseconds(50),
        readTimeout: Duration = .seconds(1),
        readPollInterval: Duration = .milliseconds(20),
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.pasteboard = pasteboard
        self.injector = injector
        self.accessibility = accessibility
        self.activationDelay = activationDelay
        self.restoreDelay = restoreDelay
        self.autoEnterDelay = autoEnterDelay
        self.readTimeout = readTimeout
        self.readPollInterval = readPollInterval
        self.sleep = sleep
    }

    // Insert `text` into the focused element of `snapshot`'s app. Re-focuses the
    // element captured at hotkey-down if focus drifted; a confirmed non-editable
    // focus skips the paste (text stays on the clipboard). Tries AX direct
    // write first (clipboard untouched on success); on failure, falls back to
    // a lazily-rendered clipboard+Cmd+V. Once an app reads the clipboard, the
    // previous clipboard is restored after `restoreDelay` (unless the user
    // copied something newer); no read within `readTimeout` throws
    // `.pasteNotConsumed` with the text left on the clipboard.
    // When `autoEnter` is true and a text field is focused, dispatches a Return
    // after the paste lands. Auto-Enter is best-effort and never surfaces as a
    // PasterError.
    // With `requiredField` (onboarding practice), nothing is refocused: the
    // system focus must be that exact editor (pid + AXIdentifier) before the AX
    // write, in the write itself, and again right before Cmd+V; otherwise
    // `.focusMoved` with the text on the clipboard.
    public func paste(
        text: String,
        target snapshot: FrontmostAppSnapshot,
        autoEnter: Bool = false,
        requiredField: FocusedField? = nil
    ) async throws {
        try await activate(target: snapshot)

        if let requiredField {
            try await ensureSystemFocus(is: requiredField, text: text)
        } else if accessibility.prepareFocus(target: snapshot) == .notEditable {
            pasteboard.writeString(text)
            throw PasterError.noEditableField
        }

        let inserted = if let requiredField {
            await onMain { $0.tryInsert(text: text, required: requiredField) }
        } else {
            accessibility.tryInsert(text: text, required: nil)
        }
        if inserted {
            await dispatchAutoEnterIfNeeded(autoEnter)
            return
        }

        if let requiredField {
            try await ensureSystemFocus(is: requiredField, text: text)
        }

        let originalClipboard = pasteboard.snapshot()
        let payload = LazyPasteboardString(text)
        guard let ourChangeCount = pasteboard.writeLazyString(payload) else {
            pasteboard.restore(originalClipboard)
            throw PasterError.clipboardWriteFailed
        }

        do {
            try injector.sendCommandV()
        } catch EventInjectorError.eventCreationFailed {
            restoreClipboard(originalClipboard, ifStillAt: ourChangeCount)
            throw PasterError.eventInjectionFailed
        }

        guard await waitForRead(payload) else {
            // Swap the promise for concrete data so the text survives a manual Cmd+V.
            if pasteboard.changeCount() == ourChangeCount {
                pasteboard.writeString(text)
            }
            throw PasterError.pasteNotConsumed
        }

        await sleep(restoreDelay)
        restoreClipboard(originalClipboard, ifStillAt: ourChangeCount)

        await dispatchAutoEnterIfNeeded(autoEnter)
    }

    private func ensureSystemFocus(is field: FocusedField, text: String) async throws {
        guard await onMain({ $0.systemFocusedField() }) == field else {
            pasteboard.writeString(text)
            throw PasterError.focusMoved
        }
    }

    // A required field lives in VoiceType itself (onboarding practice). AX on
    // an element of our own process skips IPC and runs AppKit right on the
    // calling thread; off the main thread, a write into the NSTextView
    // deadlocks against its layout.
    private func onMain<T: Sendable>(_ body: @MainActor @Sendable (AccessibilityWriterProtocol) -> T) async -> T {
        let accessibility = accessibility
        return await MainActor.run { body(accessibility) }
    }

    private func waitForRead(_ payload: LazyPasteboardString) async -> Bool {
        var waited: Duration = .zero
        while !payload.wasRead {
            guard waited < readTimeout else { return false }
            await sleep(readPollInterval)
            waited += readPollInterval
        }
        return true
    }

    // Skips the restore when the user copied something newer during the paste.
    private func restoreClipboard(_ snapshot: PasteboardSnapshot, ifStillAt changeCount: Int) {
        guard pasteboard.changeCount() == changeCount else { return }
        pasteboard.restore(snapshot)
    }

    private func dispatchAutoEnterIfNeeded(_ autoEnter: Bool) async {
        guard autoEnter, accessibility.hasFocusedTextField() else { return }
        await sleep(autoEnterDelay)
        try? injector.sendReturn()
    }

    private func activate(target snapshot: FrontmostAppSnapshot) async throws {
        guard let app = NSRunningApplication(processIdentifier: snapshot.processIdentifier) else {
            throw PasterError.targetAppNotRunning
        }
        // Best-effort: macOS 14+ may deny activation under focus-stealing
        // protection. Cmd+V still targets whatever app is currently frontmost.
        _ = app.activate()
        await sleep(activationDelay)
    }
}
