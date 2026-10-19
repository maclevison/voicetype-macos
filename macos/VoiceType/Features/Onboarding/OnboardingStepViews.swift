import Core
import SwiftUI

// MARK: - Antes de começar

/// Live status of the permissions and the local model. Never blocks: each
/// practice step lists what is still missing.
struct PrepareStepView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(MainWindowRouter.self) private var router
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let permissions = deps.permissionsChecker
        VStack(alignment: .leading, spacing: 16) {
            Text(OnboardingStrings.prepareIntro)
            permission(SettingsStrings.permissionMic, OnboardingStrings.prepareMicHelp,
                       permissions.microphone, .microphone)
            permission(SettingsStrings.permissionAccessibility, OnboardingStrings.prepareAccessibilityHelp,
                       permissions.accessibility, .accessibility)
            permission(SettingsStrings.permissionNotifications, OnboardingStrings.prepareNotificationsHelp,
                       permissions.notifications, .notifications)
            Divider()
            localModel
        }
        .task {
            // Live status while the step is on screen.
            while !Task.isCancelled {
                await deps.permissionsChecker.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func permission(_ title: String, _ help: String, _ status: PermissionStatus,
                            _ link: SystemSettingsLink) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            PermissionRow(title: title, status: status) { link.open() }
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var localModel: some View {
        let models = deps.localModels
        let selected = models.selection.selected
        let name = models.models.first { $0.id == selected }?.displayName ?? OnboardingStrings.localModelUnknown
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(OnboardingStrings.localModelLabel, systemImage: "cpu")
                Spacer()
                Text(name).fontWeight(.semibold)
                LocalModelStatusText(status: models.selection.status(of: selected))
            }
            Button(OnboardingStrings.openLocalTranscription) {
                router.show(.settings(.localTranscription), using: openWindow)
            }
            .controlSize(.small)
        }
    }
}

/// Same mapping as the model row in Configurações → Transcrição local.
private struct LocalModelStatusText: View {
    let status: LocalModelStatus

    var body: some View {
        switch status {
        case .notDownloaded:
            Text(SettingsStrings.localModelNotDownloaded).font(.caption).foregroundStyle(.secondary)
        case .downloaded:
            Text(SettingsStrings.localModelDownloaded).font(.caption).foregroundStyle(.secondary)
        case .downloading(let fraction):
            HStack(spacing: 6) {
                Text(SettingsStrings.localModelDownloading(Int(fraction * 100)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                ProgressView(value: fraction).frame(width: 80)
            }
        case .preparing:
            HStack(spacing: 6) {
                Text(SettingsStrings.localModelPreparing).font(.caption).foregroundStyle(.secondary)
                ProgressView().controlSize(.small)
            }
        case .ready:
            Text("● \(SettingsStrings.localModelReady)").font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Text(SettingsStrings.localModelFailed(message))
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}

// MARK: - Práticas

/// Dictation, hands-free and translation. The field is this session's and this
/// step's only paste destination (its AXIdentifier is the ticket's); the text
/// gets there through the `Paster`, never from the view model.
struct PracticeStepView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(MainWindowRouter.self) private var router
    @Environment(\.openWindow) private var openWindow
    @Environment(\.controlActiveState) private var controlActiveState
    let viewModel: OnboardingViewModel
    let step: OnboardingStep
    /// Bumped to put the keyboard in the field.
    @State private var focusRequest = 0
    /// The Translation framework has the dictation→target pair installed.
    @State private var appleTranslationInstalled = false

    var body: some View {
        let config = deps.configSnapshot.config
        VStack(alignment: .leading, spacing: 14) {
            instructions(config)
            let blockers = blockers(config)
            if !blockers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(OnboardingStrings.practiceMissingHeader).fontWeight(.semibold)
                    ForEach(Array(blockers.enumerated()), id: \.offset) { _, blocker in
                        blockerRow(blocker)
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            if step == .translation && viewModel.translationFellBack {
                Label(OnboardingStrings.translationFellBack, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            HStack {
                Text(OnboardingStrings.practiceFieldLabel).fontWeight(.semibold)
                Spacer()
                if viewModel.flow.isPracticed(step) {
                    Label(OnboardingStrings.practiceDone, systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
            }
            PracticeTextEditor(
                text: Binding(
                    get: { viewModel.practiceText[step, default: ""] },
                    set: { viewModel.practiceText[step] = $0 }
                ),
                identifier: viewModel.fieldIdentifier(for: step),
                focusRequest: focusRequest
            )
            .frame(height: 110)
            .id(step)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.4)))
            Text(OnboardingStrings.practiceFieldHelp).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: focusField)
        .onChange(of: step) { focusField() }
        .onChange(of: controlActiveState) { _, state in
            if state == .key { focusField() }
        }
        .task(id: step) {
            await deps.permissionsChecker.refresh()
            if #available(macOS 26, *), step == .translation {
                appleTranslationInstalled = await AppleTranslationTranslator.isInstalled(
                    from: Locale.Language(identifier: config.recording.language),
                    to: Locale.Language(identifier: config.translate.target)
                )
            }
        }
    }

    private func focusField() {
        focusRequest += 1
    }

    @ViewBuilder
    private func instructions(_ config: AppConfig) -> some View {
        let refine = ShortcutRecorderField.prettyPrint(config.shortcuts.refine)
        switch step {
        case .handsFree:
            VStack(alignment: .leading, spacing: 6) {
                Text(OnboardingStrings.handsFreeIntro(refine))
                if !config.handsFreeUpgradeKey.isEmpty {
                    Text(OnboardingStrings.handsFreeUpgrade(refine, ShortcutRecorderField.prettyPrint(config.handsFreeUpgradeKey)))
                }
                Text(OnboardingStrings.handsFreeNote).font(.caption).foregroundStyle(.secondary)
            }
        case .translation:
            Text(OnboardingStrings.translationIntro(ShortcutRecorderField.prettyPrint(config.shortcuts.translate)))
        default:
            Text(OnboardingStrings.dictationIntro(refine))
        }
    }

    private func blockers(_ config: AppConfig) -> [OnboardingBlocker] {
        let permissions = deps.permissionsChecker
        return OnboardingReadiness.blockers(
            for: step, config: config,
            microphoneGranted: permissions.microphone == .granted,
            accessibilityGranted: permissions.accessibility == .granted,
            localModelReady: deps.localModels.isReady,
            appleIntelligence: appleIntelligence,
            appleTranslationInstalled: appleTranslationInstalled
        )
    }

    private var appleIntelligence: AppleIntelligenceState {
        if #available(macOS 26, *) {
            return AIAvailability().isAvailable ? .available : .unavailable
        }
        return .unsupportedOS
    }

    private func blockerRow(_ blocker: OnboardingBlocker) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(OnboardingStrings.blocker(blocker)).font(.callout)
            HStack {
                switch blocker {
                case .accessibility:
                    Button(SettingsStrings.openSystemSettings) { SystemSettingsLink.accessibility.open() }
                case .microphone:
                    Button(SettingsStrings.openSystemSettings) { SystemSettingsLink.microphone.open() }
                case .groqKeyMissing:
                    settingsButton(OnboardingStrings.openGeneral, .general)
                case .localModelNotReady:
                    settingsButton(OnboardingStrings.openLocalTranscription, .localTranscription)
                case .translateDisabled, .handsFreeDisabled:
                    settingsButton(OnboardingStrings.openShortcuts, .shortcuts)
                case .translatorUnavailable:
                    settingsButton(OnboardingStrings.openLocalRefinement, .localRefinement)
                    settingsButton(OnboardingStrings.openGeneral, .general)
                }
            }
            .controlSize(.small)
        }
    }

    private func settingsButton(_ title: String, _ section: SettingsSection) -> some View {
        Button(title) { router.show(.settings(section), using: openWindow) }
    }
}

/// The practice field: a plain `NSTextView` carrying the ticket's AXIdentifier.
/// The `Paster` checks that identifier on the system-focused element, and
/// SwiftUI's `TextEditor` never puts `.accessibilityIdentifier` there (its text
/// view answers AXIdentifier with kAXErrorAttributeUnsupported).
struct PracticeTextEditor: NSViewRepresentable {
    @Binding var text: String
    let identifier: String
    /// A new value puts the keyboard in the field.
    let focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 2, height: 4)
        // Typing, paste and AX writes all end here, so the binding follows any of them.
        textView.textStorage?.delegate = context.coordinator
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        context.coordinator.text = $text
        if textView.string != text { textView.string = text }
        textView.setAccessibilityIdentifier(identifier)
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            // Next run loop: the view must be in the window before it can take focus.
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextStorageDelegate {
        var text: Binding<String>
        var focusRequest: Int?

        init(text: Binding<String>) {
            self.text = text
        }

        nonisolated func textStorage(
            _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange, changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            let string = textStorage.string
            MainActor.assumeIsolated {
                if text.wrappedValue != string { text.wrappedValue = string }
            }
        }
    }
}

// MARK: - Explicação

struct VoiceNoteStepView: View {
    @Environment(AppDependencies.self) private var deps

    var body: some View {
        let config = deps.configSnapshot.config
        VStack(alignment: .leading, spacing: 12) {
            if config.voiceNoteShortcut.isEmpty {
                Text(OnboardingStrings.voiceNoteOff)
            } else {
                Text(OnboardingStrings.voiceNoteIntro(ShortcutRecorderField.prettyPrint(config.voiceNoteShortcut)))
            }
            Text(config.meetingVaultKind == .openKnowledge
                 ? OnboardingStrings.voiceNoteOpenKnowledge
                 : OnboardingStrings.voiceNoteObsidian)
            Text(OnboardingStrings.voiceNoteNoPractice).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct HistoryStepView: View {
    @Environment(MainWindowRouter.self) private var router
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(OnboardingStrings.historyIntro)
            Text(OnboardingStrings.historyActions)
            Button(OnboardingStrings.openHistory) { router.show(.history, using: openWindow) }
        }
    }
}

struct MeetingsStepView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(MainWindowRouter.self) private var router
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let config = deps.configSnapshot.config
        VStack(alignment: .leading, spacing: 12) {
            Text(OnboardingStrings.meetingsDetection(config.meetingDetectionMode))
            Text(OnboardingStrings.meetingsMenu)
            Text(config.meetingVaultKind == .openKnowledge
                 ? OnboardingStrings.meetingsOpenKnowledge
                 : OnboardingStrings.meetingsObsidian)
            Button(OnboardingStrings.openMeetings) { router.show(.settings(.meetings), using: openWindow) }
        }
    }
}

struct PersonalizeStepView: View {
    @Environment(MainWindowRouter.self) private var router
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(OnboardingStrings.personalizeIntro)
            link(OnboardingStrings.refineStyleLink, OnboardingStrings.refineStyleHelp, "textformat", .refineStyle)
            link(OnboardingStrings.vocabularyLink, OnboardingStrings.vocabularyHelp, "character.book.closed", .vocabulary)
            link(OnboardingStrings.openKnowledgeLink, OnboardingStrings.openKnowledgeHelp, "person.2.wave.2", .meetings)
            Text(OnboardingStrings.personalizeReopen).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func link(_ title: String, _ help: String, _ icon: String, _ section: SettingsSection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                router.show(.settings(section), using: openWindow)
            } label: {
                Label(title, systemImage: icon)
            }
            .buttonStyle(.link)
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }
}
