import ApplicationServices
import Foundation

// `AXUIElement` is an immutable CF reference and the AX C API may be called
// from any thread, but the type is not annotated `Sendable`. This wrapper lets
// the element captured at hotkey-down ride inside `FrontmostAppSnapshot` to
// the `Paster` actor; it is only ever handed back to AX calls, never mutated.
public struct AXElementRef: @unchecked Sendable, Equatable {
    public let element: AXUIElement

    public init(_ element: AXUIElement) {
        self.element = element
    }

    // Focused element of the app `pid`. Nil when AX is not granted, the app
    // exposes no focus, or it does not answer (common in Electron apps).
    public static func focused(inApp pid: pid_t) -> AXElementRef? {
        let app = AXUIElementCreateApplication(pid)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused as! AXUIElement? else {
            return nil
        }
        return AXElementRef(element)
    }

    public static func == (lhs: AXElementRef, rhs: AXElementRef) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}

// A focused element's owner and AXIdentifier. The onboarding practice requires
// this exact pair to paste (`Paster.paste(requiredField:)`).
public struct FocusedField: Equatable, Sendable {
    public let pid: pid_t
    public let identifier: String?

    public init(pid: pid_t, identifier: String?) {
        self.pid = pid
        self.identifier = identifier
    }
}

public enum FocusEditability: Sendable, Equatable {
    case editable
    // Confirmed: nothing to paste into. Callers skip Cmd+V.
    case notEditable
    // AX gave no usable answer. Callers keep the blind Cmd+V fallback.
    case unknown
}

public protocol AccessibilityWriterProtocol: Sendable {
    // Best-effort direct write to the focused text element via Accessibility.
    // Returns true iff the focused element's value/selectedText/selectedRange
    // demonstrably changed — apps that report AX success but ignore the write
    // (e.g. some Electron, secure inputs) yield false so the caller can fall back.
    // With `required`, the focused text element is read once, and the write is
    // skipped (false) unless that same element has the required pid and
    // AXIdentifier — a focus change mid-check can't redirect the write.
    func tryInsert(text: String, required: FocusedField?) -> Bool

    // The system-wide focused element (the one that gets the keyboard, so
    // Cmd+V): its pid and AXIdentifier. Nil when AX gives no answer.
    func systemFocusedField() -> FocusedField?

    // Read-only probe: returns true when the system-focused element has a
    // text-bearing AX role. Used to gate auto-Enter so Return is not dispatched
    // into apps without a text input focused.
    func hasFocusedTextField() -> Bool

    // Runs after the target app is activated. If the app's current focus is
    // not editable, re-focuses `snapshot.focusedElement` (captured at
    // hotkey-down) when it is still alive. An editable current focus wins: the
    // user moved there on purpose. Returns the editability of the final focus.
    func prepareFocus(target snapshot: FrontmostAppSnapshot) -> FocusEditability
}

public extension AccessibilityWriterProtocol {
    func tryInsert(text: String) -> Bool {
        tryInsert(text: text, required: nil)
    }
}

public struct SystemAccessibilityWriter: AccessibilityWriterProtocol {
    public init() {}

    public func tryInsert(text: String, required: FocusedField?) -> Bool {
        guard let element = Self.focusedTextElement() else { return false }
        if let required, Self.field(of: element) != required { return false }
        guard let before = Self.focusedTextState(for: element) else { return false }

        let result = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        guard result == .success else { return false }

        guard let after = Self.focusedTextState(for: element) else { return false }
        return Self.focusedTextDidChange(from: before, to: after)
    }

    public func hasFocusedTextField() -> Bool {
        Self.focusedTextElement() != nil
    }

    public func systemFocusedField() -> FocusedField? {
        Self.systemFocusedElement().flatMap(Self.field(of:))
    }

    public func prepareFocus(target snapshot: FrontmostAppSnapshot) -> FocusEditability {
        let current = AXElementRef.focused(inApp: snapshot.processIdentifier)
        let currentEditability = Self.editability(of: current?.element, bundleIdentifier: snapshot.bundleIdentifier)
        guard currentEditability != .editable,
              let original = snapshot.focusedElement,
              original != current,
              Self.editability(of: original.element, bundleIdentifier: snapshot.bundleIdentifier) == .editable else {
            return currentEditability
        }

        // Stale/destroyed elements fail here with kAXErrorInvalidUIElement —
        // no crash, we just keep the current focus.
        if let window = Self.elementAttribute(kAXWindowAttribute as CFString, from: original.element) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        let result = AXUIElementSetAttributeValue(original.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return result == .success ? .editable : currentEditability
    }

    static func editability(of element: AXUIElement?, bundleIdentifier: String) -> FocusEditability {
        guard let element else {
            return classify(role: nil, isTextSettable: false, bundleIdentifier: bundleIdentifier)
        }
        var settable = DarwinBoolean(false)
        let valueSettable = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
        settable = false
        let selectionSettable = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue
        return classify(
            role: stringAttribute(kAXRoleAttribute as CFString, from: element),
            isTextSettable: valueSettable || selectionSettable,
            bundleIdentifier: bundleIdentifier
        )
    }

    // Fail-open by design: only a positive "this cannot take text" answer
    // yields .notEditable. Text roles with read-only value (Terminal) and
    // silent apps (Electron without AX) stay .unknown → Cmd+V as before.
    static func classify(role: String?, isTextSettable: Bool, bundleIdentifier: String) -> FocusEditability {
        if isTextSettable { return .editable }
        if let role, textRoles.contains(role) { return .unknown }
        // Finder/desktop: outside rename/search fields there is never a text target.
        if bundleIdentifier == "com.apple.finder" { return .notEditable }
        if let role, nonEditableRoles.contains(role) { return .notEditable }
        return .unknown
    }

    // MARK: - AX gymnastics (hidden from callers)

    private static let textRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField",
        "AXWebArea"
    ]

    // ponytail: conservative denylist — roles that never accept pasted text in
    // apps seen so far. AXGroup/AXScrollArea/AXTable are left out on purpose
    // (Electron/web/Numbers report them while editing). Grow from smoke data.
    private static let nonEditableRoles: Set<String> = [
        "AXList",
        "AXOutline",
        "AXBrowser",
        "AXImage",
        "AXButton",
        "AXCheckBox",
        "AXRadioButton",
        "AXPopUpButton",
        "AXMenuButton"
    ]

    private struct FocusedTextState {
        let value: String?
        let selectedText: String?
        let selectedRange: NSRange?
    }

    private static func systemFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused as! AXUIElement? else {
            return nil
        }
        return element
    }

    private static func field(of element: AXUIElement) -> FocusedField? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return FocusedField(pid: pid, identifier: stringAttribute(kAXIdentifierAttribute as CFString, from: element))
    }

    private static func focusedTextElement() -> AXUIElement? {
        guard let element = systemFocusedElement() else { return nil }

        var roleValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String,
              textRoles.contains(role) else {
            return nil
        }
        return element
    }

    private static func focusedTextState(for element: AXUIElement) -> FocusedTextState? {
        FocusedTextState(
            value: stringAttribute(kAXValueAttribute as CFString, from: element),
            selectedText: stringAttribute(kAXSelectedTextAttribute as CFString, from: element),
            selectedRange: selectedRangeAttribute(from: element)
        )
    }

    private static func focusedTextDidChange(
        from initial: FocusedTextState,
        to current: FocusedTextState
    ) -> Bool {
        initial.value != current.value ||
        initial.selectedText != current.selectedText ||
        initial.selectedRange != current.selectedRange
    }

    private static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func elementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func selectedRangeAttribute(from element: AXUIElement) -> NSRange? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let rangeValue = value else {
            return nil
        }

        var range = CFRange()
        guard CFGetTypeID(rangeValue) == AXValueGetTypeID(),
              AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }
}
