import AppKit
import Core
import Foundation

/// Composition root for the app target.
///
/// Owns the long-lived collaborator graph (Core actors + AppKit-bound singletons)
/// and is constructed once in `VoiceTypeApp.init`. Views consume the instance
/// through `@Environment(AppDependencies.self)`; `AppDelegate` receives the same
/// instance via the static `injectedDeps` handoff slot (see `AppDelegate.swift`).
///
/// `configSnapshot` and `historySnapshot` are `@Observable` MainActor views over
/// the underlying Core actors. Views read state through the snapshots; writes still
/// go through `configStore.save` / `configSnapshot.update` / `historyStore` directly.
///
/// Singletons are intentionally absent here apart from Apple-mandated APIs
/// (`NSApp`, `NSWorkspace.shared`, `UNUserNotificationCenter.current()`) which
/// the underlying collaborators consume directly.
@MainActor
@Observable
final class AppDependencies {
    let configStore: ConfigStore
    let historyStore: HistoryStore
    let suggestionStore: SuggestionStore
    let configSnapshot: ConfigStoreSnapshot
    let historySnapshot: HistoryStoreSnapshot
    let notifier: Notifier
    let permissionsChecker: PermissionsChecker
    let hudController: HUDController
    let soundFeedback: SoundFeedbackService
    let localModels: LocalModelManager
    let recordingOrchestrator: RecordingOrchestrator
    /// Shared by the onboarding window and the orchestrator (practice takes).
    let onboardingPractice: OnboardingPracticeSink
    let meetingRecorder: MeetingRecorder
    let pendingApprovals: PendingApprovals
    let meetingDetector: MeetingDetector

    init(
        configStore: ConfigStore = ConfigStore(),
        historyStore: HistoryStore = HistoryStore(),
        suggestionStore: SuggestionStore = SuggestionStore(),
        notifier: Notifier? = nil,
        permissionsChecker: PermissionsChecker? = nil,
        hudController: HUDController? = nil,
        paster: Paster? = nil,
        recorder: AudioRecorderProtocol? = nil,
        soundFeedback: SoundFeedbackService? = nil
    ) {
        self.configStore = configStore
        self.historyStore = historyStore
        self.suggestionStore = suggestionStore
        self.configSnapshot = ConfigStoreSnapshot(store: configStore)
        self.historySnapshot = HistoryStoreSnapshot(store: historyStore)

        let resolvedNotifier = notifier ?? Notifier()
        let resolvedPermissions = permissionsChecker ?? PermissionsChecker()
        let resolvedHud = hudController ?? HUDController()
        let resolvedSoundFeedback = soundFeedback ?? SoundFeedbackService()

        self.notifier = resolvedNotifier
        self.permissionsChecker = resolvedPermissions
        self.hudController = resolvedHud
        self.soundFeedback = resolvedSoundFeedback

        let configSnapshot = self.configSnapshot
        let resolvedLocalModels = LocalModelManager(persist: { id in
            Task { await configSnapshot.update { $0.localTranscriptionModel = id } }
        })
        self.localModels = resolvedLocalModels
        // The app is also the unit-test host: there, loading the user's model
        // would read, repair or download the real files in Application Support.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            Task {
                let selectedID = (try? await configStore.load())?.localTranscriptionModel ?? LocalModelCatalog.defaultID
                resolvedLocalModels.bootstrap(selectedID: selectedID)
            }
        }

        let onboardingPractice = OnboardingPracticeSink()
        self.onboardingPractice = onboardingPractice
        self.recordingOrchestrator = RecordingOrchestrator(
            configStore: configStore,
            historyStore: historyStore,
            notifier: resolvedNotifier,
            hudController: resolvedHud,
            paster: paster ?? Paster(),
            recorder: recorder ?? AudioRecorder(),
            soundFeedback: resolvedSoundFeedback,
            localModels: resolvedLocalModels,
            editObserver: EditObserver(store: suggestionStore),
            practiceSink: onboardingPractice
        )
        let pendingApprovals = PendingApprovals(notifier: resolvedNotifier)
        self.pendingApprovals = pendingApprovals
        self.meetingRecorder = MeetingRecorder(configStore: configStore, notifier: resolvedNotifier, onPendingChanged: {
            await pendingApprovals.refresh()
        })
        self.meetingDetector = MeetingDetector(recorder: meetingRecorder, config: configSnapshot, notifier: resolvedNotifier)
    }
}
