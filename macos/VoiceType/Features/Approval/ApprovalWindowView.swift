import Core
import SwiftUI

/// The approval window: one `ApprovalViewModel` per meeting the menu picked.
struct ApprovalWindowView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(ApprovalRouter.self) private var router
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var viewModel: ApprovalViewModel?

    var body: some View {
        Group {
            if let viewModel {
                ApprovalContent(viewModel: viewModel) { dismissWindow(id: ApprovalRouter.windowID) }
            } else {
                Text(ApprovalStrings.noMeeting).padding(24)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .task(id: router.meetingDirectory) {
            guard let dir = router.meetingDirectory else {
                viewModel = nil
                return
            }
            let vm = ApprovalViewModel(
                directory: dir, configStore: deps.configStore, notifier: deps.notifier, pending: deps.pendingApprovals,
                assistantFactory: { path in
                    ClaudeCLISummarizer.locate(configured: path).map { ClaudeCLISummarizer(executableURL: $0) }
                }
            )
            viewModel = vm
            await vm.load()
        }
    }
}

private struct ApprovalContent: View {
    @Bindable var viewModel: ApprovalViewModel
    let close: () -> Void

    @State private var selectedProject: String?
    @State private var showsNewProject = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let banner = viewModel.banner {
                notice(banner, color: .orange)
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .sheet(isPresented: $showsNewProject) {
            NewProjectSheet(existing: viewModel.projects) { slug, description in
                try await viewModel.createProject(slug: slug, description: description)
            }
        }
        .onChange(of: viewModel.session?.chosenProject, initial: true) { _, chosen in
            selectedProject = chosen
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let session = viewModel.session {
                Text(session.proposal.note.summary.title).font(.title2.bold()).lineLimit(2)
                HStack {
                    Text(session.proposal.note.startedAt.formatted(date: .abbreviated, time: .shortened))
                    Spacer()
                    if viewModel.vaultMismatch == nil {
                        Text(ApprovalStrings.stepCounter(min(session.progress.stepIndex, session.steps.count - 1) + 1, of: session.steps.count))
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                Text(ApprovalStrings.windowTitle).font(.title2.bold())
            }
        }
        .padding(16)
    }

    private func notice(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .textSelection(.enabled)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.journalPending {
            notice(ApprovalStrings.journalPending, color: .orange).padding(.top, 16)
        } else if let mismatch = viewModel.vaultMismatch {
            VStack(alignment: .leading, spacing: 12) {
                Text(ApprovalStrings.vaultMismatch(prepared: mismatch.prepared, current: mismatch.current))
                Button(ApprovalStrings.prepareAgain(mismatch.current)) {
                    Task { await viewModel.prepareForCurrentVault() }
                }
                .disabled(viewModel.isDistilling)
            }
            .padding(16)
        } else if let session = viewModel.session {
            switch session.current {
            case .project: projectStep(session)
            case .record, .item: contentStep(session)
            }
        }
    }

    @ViewBuilder
    private func projectStep(_ session: OKApprovalSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ApprovalStrings.projectStep).font(.headline)
            if session.projectLocked {
                Text(ApprovalStrings.projectLocked(session.proposal.project ?? ""))
            } else {
                TextField(ApprovalStrings.searchProjects, text: $viewModel.search)
                    .textFieldStyle(.roundedBorder)
                List(viewModel.filteredProjects, selection: $selectedProject) { project in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(project.title)
                            Text(project.slug).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        if project.slug == session.proposal.suggestedProject {
                            Text(ApprovalStrings.suggested)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .background(Color.accentColor.opacity(0.2), in: Capsule())
                        }
                    }
                    .tag(project.slug as String?)
                }
                .listStyle(.bordered)
                Button(ApprovalStrings.newProject) { showsNewProject = true }
            }
        }
        .padding(16)
        .disabled(viewModel.isDistilling)
    }

    @ViewBuilder
    private func contentStep(_ session: OKApprovalSession) -> some View {
        let step = session.current
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label(step, session)).font(.headline)
                Text(destination(step, session)).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Picker("", selection: $viewModel.tab) {
                    Text(ApprovalStrings.preview).tag(ApprovalViewModel.Tab.preview)
                    Text(ApprovalStrings.editor).tag(ApprovalViewModel.Tab.editor)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if step == .record {
                if let failure = session.proposal.summaryFailure {
                    notice(ApprovalStrings.summaryFailure(failure), color: .yellow).padding(.horizontal, -16)
                } else if let failure = session.proposal.distillationError {
                    HStack {
                        notice(ApprovalStrings.distillationError(failure), color: .yellow).padding(.horizontal, -16)
                        Button(ApprovalStrings.retryDistillation) { Task { await viewModel.retryDistillation() } }
                            .disabled(viewModel.isBlocked)
                    }
                }
            }
            switch viewModel.tab {
            case .preview:
                MarkdownPreview(html: OKMarkdownHTML.document(session.markdown(for: step), previous: session.previousMarkdown(for: step)))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            case .editor:
                TextEditor(text: Binding(get: { session.markdown(for: step) }, set: { viewModel.edit($0) }))
                    .font(.body.monospaced())
                    .disabled(viewModel.isBlocked)
                HStack {
                    Spacer()
                    Button(ApprovalStrings.undoEdits) { viewModel.undoEdits() }
                        .disabled(!viewModel.currentHasEdit || viewModel.isBlocked)
                }
            }
        }
        .padding(16)
    }

    private func label(_ step: OKApprovalSession.Step, _ session: OKApprovalSession) -> String {
        switch step {
        case .project: return ApprovalStrings.projectStep
        case .record: return ApprovalStrings.recordLabel
        case let .item(id):
            guard let item = session.proposal.items.first(where: { $0.id == id }) else { return "" }
            if item.conflict { return ApprovalStrings.conflictItem }
            return item.action == .new ? ApprovalStrings.newItem(item.type) : ApprovalStrings.updateItem(item.type)
        }
    }

    private func destination(_ step: OKApprovalSession.Step, _ session: OKApprovalSession) -> String {
        switch step {
        case .project: ""
        case .record: session.paths?.record ?? ""
        case let .item(id): session.proposal.items.first { $0.id == id }?.path ?? ""
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if viewModel.isDistilling {
                ProgressView().controlSize(.small)
                Text(viewModel.progressText ?? "").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let session = viewModel.session, viewModel.vaultMismatch == nil, !viewModel.journalPending {
                Button(ApprovalStrings.back) { viewModel.back() }
                    .disabled(viewModel.isBlocked || session.progress.stepIndex == 0)
                if case .item = session.current, !session.isFinished {
                    Button(ApprovalStrings.skip) { viewModel.skip() }
                        .disabled(viewModel.isBlocked)
                }
                if session.isFinished {
                    Button(ApprovalStrings.commit) {
                        Task { if await viewModel.commit() { close() } }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.isBlocked || !session.canCommit)
                } else {
                    Button(ApprovalStrings.approve) { approve(session) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(viewModel.isBlocked || (session.current == .project && selectedProject == nil && !session.projectLocked))
                }
            }
        }
        .padding(12)
    }

    /// On the project step "Aprovar" first applies the selected project; a
    /// change of project prepares the proposal and moves to the first
    /// pending step by itself.
    private func approve(_ session: OKApprovalSession) {
        guard session.current == .project, !session.projectLocked, let selected = selectedProject else {
            viewModel.approve()
            return
        }
        Task {
            await viewModel.choose(selected)
            if viewModel.session?.current == .project { viewModel.approve() }
        }
    }
}
