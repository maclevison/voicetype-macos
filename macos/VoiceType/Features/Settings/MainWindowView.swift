import SwiftUI
import Core

/// The app's single window: History on top, settings sections below.
enum MainDestination: Hashable {
    case history
    case settings(SettingsSection)
}

/// Selected destination, shared with the menu bar so "Histórico…" and
/// "Configurações…" deep-link into the window even when it is already open.
@MainActor @Observable
final class MainWindowRouter {
    static let windowID = "main"
    var selection: MainDestination? = .settings(.general)
}

struct MainWindowView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(MainWindowRouter.self) private var router
    let historyViewModel: HistoryViewModel

    var body: some View {
        @Bindable var router = router
        NavigationSplitView {
            List(selection: $router.selection) {
                Label(HistoryStrings.title, systemImage: "clock.arrow.circlepath")
                    .tag(MainDestination.history)
                Section(SettingsStrings.header) {
                    ForEach(SettingsSection.allCases) { section in
                        Label(section.label, systemImage: section.systemImage)
                            .tag(MainDestination.settings(section))
                    }
                }
            }
            .frame(minWidth: 180)
        } detail: {
            Group {
                switch router.selection ?? .settings(.general) {
                case .history:
                    HistoryView(viewModel: historyViewModel)
                case .settings(let section):
                    detail(section)
                }
            }
            .frame(minWidth: 640, minHeight: 420)
            .task { await deps.permissionsChecker.refresh() }
        }
        .frame(minWidth: 900, minHeight: 480)
    }

    @ViewBuilder
    private func detail(_ section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSection(snapshot: deps.configSnapshot)
        case .shortcuts:
            ShortcutsSection(snapshot: deps.configSnapshot)
        case .audio:
            AudioSection(snapshot: deps.configSnapshot, permissions: deps.permissionsChecker)
        case .localTranscription:
            LocalTranscriptionSection(snapshot: deps.configSnapshot, models: deps.localModels)
        case .localRefinement:
            LocalRefinementSection(snapshot: deps.configSnapshot)
        case .refineStyle:
            RefineStyleSection(snapshot: deps.configSnapshot)
        case .vocabulary:
            VocabularySection(snapshot: deps.configSnapshot, suggestions: deps.suggestionStore)
        case .appearance:
            AppearanceSection(snapshot: deps.configSnapshot)
        case .history:
            HistorySection(snapshot: deps.configSnapshot)
        case .meetings:
            MeetingSection(snapshot: deps.configSnapshot)
        case .startup:
            StartupSection(
                snapshot: deps.configSnapshot,
                permissions: deps.permissionsChecker,
                notifier: deps.notifier
            )
        case .about:
            AboutSection()
        }
    }
}
