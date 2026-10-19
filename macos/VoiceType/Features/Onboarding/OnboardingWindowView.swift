import Core
import SwiftUI

enum OnboardingWindow {
    static let id = "onboarding"
}

/// The onboarding window. One `OnboardingViewModel` per opening, created on
/// appear and dropped on disappear, so reopening from the menu starts at step 1
/// with a new practice session.
struct OnboardingWindowView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var viewModel: OnboardingViewModel?

    var body: some View {
        Group {
            if let viewModel {
                OnboardingContent(viewModel: viewModel) {
                    Task {
                        await viewModel.finish()
                        dismissWindow(id: OnboardingWindow.id)
                    }
                }
            } else {
                Color.clear
            }
        }
        .frame(width: 640, height: 520)
        .onAppear {
            if viewModel == nil {
                viewModel = OnboardingViewModel(snapshot: deps.configSnapshot, sink: deps.onboardingPractice)
            }
            viewModel?.windowKeyChanged(controlActiveState == .key)
        }
        .onChange(of: controlActiveState) { _, state in
            viewModel?.windowKeyChanged(state == .key)
        }
        .onDisappear {
            guard let closing = viewModel else { return }
            viewModel = nil
            Task { await closing.windowClosed() }
        }
    }
}

private struct OnboardingContent: View {
    let viewModel: OnboardingViewModel
    let finish: () -> Void

    private var flow: OnboardingFlow { viewModel.flow }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                step
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(24)
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(OnboardingStrings.title(flow.current)).font(.title2.bold())
                Spacer()
                Text(OnboardingStrings.progress(flow.position, flow.total))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: flow.progress)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var step: some View {
        switch flow.current {
        case .prepare:
            PrepareStepView()
        case .dictation, .handsFree, .translation:
            PracticeStepView(viewModel: viewModel, step: flow.current)
        case .voiceNote:
            VoiceNoteStepView()
        case .history:
            HistoryStepView()
        case .meetings:
            MeetingsStepView()
        case .personalize:
            PersonalizeStepView()
        }
    }

    // No default-action shortcut: Return (or the Paster's auto-Enter) in the
    // practice field must never turn the page.
    private var footer: some View {
        HStack {
            Button(OnboardingStrings.back) { viewModel.back() }
                .disabled(!flow.canGoBack)
            Spacer()
            if flow.isLast {
                Button(OnboardingStrings.finish, action: finish)
                    .buttonStyle(.borderedProminent)
            } else {
                Button(OnboardingStrings.next) { viewModel.next() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}
