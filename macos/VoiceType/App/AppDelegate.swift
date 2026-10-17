import AppKit
import Core
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Composition handoff
    //
    // `NSApplicationDelegateAdaptor` instantiates `AppDelegate` before
    // `VoiceTypeApp.body` runs, which means we can't pass `AppDependencies`
    // through `init`. `VoiceTypeApp.init` assigns this static slot just
    // before the SwiftUI scene graph is constructed, and
    // `applicationDidFinishLaunching` reads it on the same main thread.
    static var injectedDeps: AppDependencies?

    private var deps: AppDependencies!
    private var holdDetector: HoldDetector?
    private var shortcutManager: ShortcutManager?
    private var stateMachine: AppStateMachine?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let injected = AppDelegate.injectedDeps else {
            fatalError("AppDependencies not injected before applicationDidFinishLaunching — VoiceTypeApp.init is expected to set AppDelegate.injectedDeps.")
        }
        deps = injected

        // Menu-bar-only app. .accessory hides the Dock icon and keeps the app alive
        // when no windows are open. Combined with LSUIElement=YES in Info.plist this
        // is the canonical menu-bar app setup. See spec §5.2 (AppDelegate).
        NSApp.setActivationPolicy(.accessory)

        // MenuBar UI is owned by SwiftUI's `MenuBarExtra` scene (see VoiceTypeApp).
        // The Settings scene is wired via the same App body, so `SettingsLink`
        // in the menu opens it natively — no AppKit `showSettingsWindow:` bridge.

        // Meeting-tap aggregates left behind by a crash mid-recording (#74).
        SystemAudioCapture.destroyOrphanAggregates()
        // Polls who holds the mic; ask/auto record on meeting start (#74).
        deps.meetingDetector.start()
        // Drops audio of meetings whose note is older than the retention (#74).
        deps.meetingRecorder.purgeOldAudio()
        // Finishes or undoes OpenKnowledge vault writes a crash interrupted, then lists the pending approvals.
        deps.pendingApprovals.bootstrap()

        deps.recordingOrchestrator.start()
        PasteKeyCode.startObserving()

        // Phase 4 — Accessibility status check + push-to-talk wiring.
        // Use `prompt: false`: the TCC prompt only succeeds the first time
        // anyway, and after that it nags the user every launch from an
        // ad-hoc-signed dev build. Status is exposed live in
        // Settings → Inicialização → Permissões, and tapping "Abrir
        // Configurações" deep-links to the System Settings pane where the
        // user can grant access manually.
        let trusted = AccessibilityChecker.isTrusted(prompt: false)
        if !trusted {
            NSLog("[bootstrap] Accessibility not granted — push-to-talk inert until granted in System Settings → Privacy & Security → Accessibility (HoldDetector polls and installs the tap on grant).")
            let notifier = deps.notifier
            Task { @MainActor in
                await notifier.error(
                    title: NotificationCopy.accessibilityMissingTitle,
                    body: NotificationCopy.accessibilityMissingBody
                )
            }
        }

        let detector = HoldDetector()
        let permissionsOnGrant = deps.permissionsChecker
        detector.onAccessibilityGranted = {
            Task { @MainActor in await permissionsOnGrant.refresh() }
        }
        let secureInputNotifier = deps.notifier
        detector.onSecureInputEnabled = { ownerApp in
            Task { @MainActor in
                await secureInputNotifier.info(
                    title: NotificationCopy.secureInputTitle,
                    body: NotificationCopy.secureInputBody(ownerApp: ownerApp)
                )
            }
        }
        let manager = ShortcutManager(configStore: deps.configStore, holdDetector: detector)
        let machine = AppStateMachine()
        // 5-min cap: finish the take like a key release (stop + process), not drop it.
        let capNotifier = deps.notifier
        Task {
            await machine.onTimeout { [detector] in
                detector.forceRelease()
                Task { @MainActor in
                    await capNotifier.info(title: NotificationCopy.recordingCapTitle, body: NotificationCopy.recordingCapBody)
                }
            }
        }

        self.holdDetector = detector
        self.shortcutManager = manager
        self.stateMachine = machine

        let configStore = deps.configStore
        Task {
            _ = try? await configStore.seedFirstRunShortcut(hasAppleFnKey: KeyboardHardware.hasAppleFnKey())
            await manager.applyConfig()
            // Subscribe to config changes so re-saving Settings updates registrations.
            _ = configStore.subscribe { _ in
                Task { @MainActor in
                    await manager.applyConfig()
                }
            }
        }

        deps.recordingOrchestrator.wireShortcuts(stateMachine: machine, shortcutManager: manager)

        // Phase 6 — bootstrap permission status snapshot so Settings sections
        // see real values the moment they open.
        let permissions = deps.permissionsChecker
        Task { @MainActor in
            await permissions.refresh()
        }

        // Phase 8 — request notification authorization once at launch and
        // mirror the cached value into the PermissionsChecker so the
        // Notifications row in Settings → Inicialização reflects reality.
        let notifier = deps.notifier
        notifier.onAuthChanged = { [weak permissions] authorized in
            Task { @MainActor in
                permissions?.setNotificationsAuthorized(authorized)
            }
        }
        Task { @MainActor in
            await notifier.bootstrap()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Refresh permission snapshot whenever the user returns to the app —
        // catches grants/revocations made in System Settings without us being
        // foreground.
        holdDetector?.retryTapIfPending()
        guard let deps else { return }
        let permissions = deps.permissionsChecker
        Task { @MainActor in
            await permissions.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Close the meeting segments so the CAF headers + manifest are final.
        deps?.meetingRecorder.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // We're a menu-bar-only app. Closing the Settings window must keep
        // the app running.
        return false
    }
}
