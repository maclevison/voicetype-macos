import AppKit

public struct FrontmostAppSnapshot: Equatable, Sendable {
    public let bundleIdentifier: String
    public let processIdentifier: pid_t
    public let localizedName: String
    // Focused AX element at capture time; the Paster re-focuses it if focus
    // drifted during recording. Nil when AX had no answer.
    public let focusedElement: AXElementRef?

    public init(
        bundleIdentifier: String,
        processIdentifier: pid_t,
        localizedName: String,
        focusedElement: AXElementRef? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.localizedName = localizedName
        self.focusedElement = focusedElement
    }
}

public enum FocusedApp {
    // Captures the current frontmost app. Returns nil if it's VoiceType itself or if
    // NSWorkspace reports no frontmost app (rare, possible during fast Spaces switches).
    @MainActor public static func snapshot() -> FrontmostAppSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleID = app.bundleIdentifier ?? ""
        if bundleID == (Bundle.main.bundleIdentifier ?? "") { return nil }
        return FrontmostAppSnapshot(
            bundleIdentifier: bundleID,
            processIdentifier: app.processIdentifier,
            localizedName: app.localizedName ?? bundleID,
            focusedElement: AXElementRef.focused(inApp: app.processIdentifier)
        )
    }

    /// VoiceType itself as the target, without any AX query (no focused
    /// element). Only the onboarding practice uses it.
    @MainActor public static func ownApp() -> FrontmostAppSnapshot {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        return FrontmostAppSnapshot(
            bundleIdentifier: bundleID,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            localizedName: NSRunningApplication.current.localizedName ?? bundleID
        )
    }
}
