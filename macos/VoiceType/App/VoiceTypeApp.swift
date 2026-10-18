import AppKit
import Core
import SwiftUI

@main
struct VoiceTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var deps: AppDependencies
    @State private var historyViewModel: HistoryViewModel
    @State private var router = MainWindowRouter()
    @State private var approvalRouter = ApprovalRouter()

    init() {
        // Build the composition graph once and hand the same instance to the
        // AppDelegate via a static slot before SwiftUI computes the body.
        // `NSApplicationDelegateAdaptor` instantiates AppDelegate before
        // `body` runs, so we can't pass deps through delegate init directly.
        let deps = AppDependencies()
        AppDelegate.injectedDeps = deps

        _deps = State(initialValue: deps)
        _historyViewModel = State(initialValue: HistoryViewModel(
            snapshot: deps.historySnapshot,
            store: deps.historyStore,
            paster: LivePaster(paster: deps.recordingOrchestrator.paster)
        ))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(deps)
                .environment(router)
                .environment(approvalRouter)
        } label: {
            // Red dot next to the icon while a meeting records — visible without opening the menu.
            if deps.meetingRecorder.isRecording {
                Image(nsImage: MenuBarIconRecording.image)
            } else {
                Image("MenuBarIcon")
            }
        }
        .menuBarExtraStyle(.menu)

        // Dedicated Window scene (not `Settings { }`): LSUIElement apps can't
        // foreground the SwiftUI Settings scene reliably — the OS attaches it
        // as a child of whatever's frontmost. A Window with its own id has its
        // own lifecycle and we toggle activation policy around its lifetime so
        // the Dock icon appears only while the window is visible.
        Window("VoiceType", id: MainWindowRouter.windowID) {
            MainWindowView(historyViewModel: historyViewModel)
                .environment(deps)
                .environment(router)
                .onAppear { ActivationPolicyTracker.enter() }
                .onDisappear { ActivationPolicyTracker.leave() }
        }
        .windowResizability(.contentMinSize)
        .commandsRemoved()

        // OpenKnowledge approvals: opened only from the menu's pending list,
        // never by itself.
        Window(ApprovalStrings.windowTitle, id: ApprovalRouter.windowID) {
            ApprovalWindowView()
                .environment(deps)
                .environment(approvalRouter)
                .onAppear { ActivationPolicyTracker.enter() }
                .onDisappear { ActivationPolicyTracker.leave() }
        }
        .windowResizability(.contentMinSize)
        .commandsRemoved()
    }
}

/// Menu-bar icon + red recording dot, drawn once. Non-template so the red
/// survives (template images are recolored monochrome by the menu bar).
enum MenuBarIconRecording {
    @MainActor static let image: NSImage = {
        let base = NSImage(named: "MenuBarIcon") ?? NSImage()
        let h: CGFloat = 18
        let iconW = base.size.height > 0 ? base.size.width * h / base.size.height : h
        let dot: CGFloat = 7
        let img = NSImage(size: NSSize(width: iconW + 3 + dot, height: h), flipped: false) { _ in
            let tint = NSColor.labelColor
            let icon = NSImage(size: NSSize(width: iconW, height: h), flipped: false) { r in
                base.draw(in: r)
                tint.set()
                r.fill(using: .sourceAtop)
                return true
            }
            icon.draw(in: NSRect(x: 0, y: 0, width: iconW, height: h))
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: iconW + 3, y: (h - dot) / 2, width: dot, height: dot)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }()
}
