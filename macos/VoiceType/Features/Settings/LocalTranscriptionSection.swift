import SwiftUI
import Core

struct LocalTranscriptionSection: View {
    let snapshot: ConfigStoreSnapshot
    let models: LocalModelManager

    var body: some View {
        Form {
            Section(SettingsStrings.localTranscriptionHeader) {
                Picker(SettingsStrings.localTranscriptionEngineLabel, selection: Binding(
                    get: { snapshot.config.transcriptionEngine },
                    set: { v in Task { await snapshot.update { $0.transcriptionEngine = v } } }
                )) {
                    Text(SettingsStrings.engineAuto).tag("auto")
                    Text(SettingsStrings.engineLocal).tag("local")
                    Text(SettingsStrings.engineGroq).tag("groq")
                }
            }
            Section {
                ForEach(models.models) { model in
                    LocalModelRow(
                        model: model,
                        models: models,
                        vocabularyCount: vocabularyCount
                    )
                }
            } header: {
                Text(SettingsStrings.localModelHeader)
            } footer: {
                Text(SettingsStrings.localModelFirstLoadNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text(SettingsStrings.localTranscriptionRefineNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SettingsStrings.localTranscriptionHeader)
    }

    private var vocabularyCount: Int {
        VocabularyTerms.parse(snapshot.config.vocabularyKeywords).count
    }
}

private struct LocalModelRow: View {
    let model: LocalModel
    let models: LocalModelManager
    let vocabularyCount: Int

    private var selection: LocalModelSelection { models.selection }
    private var status: LocalModelStatus { selection.status(of: model.id) }
    private var isSelected: Bool { selection.selected == model.id }
    private var isBusy: Bool { model.id == selection.active || model.id == selection.pending }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { models.select(model.id) } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName).fontWeight(.semibold)
                        Text(model.summary).font(.caption).foregroundStyle(.secondary)
                        if isSelected, !model.supportsVocabulary, vocabularyCount > 0 {
                            Label(SettingsStrings.localModelVocabularyIgnored(vocabularyCount),
                                  systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.localModel.\(model.id).select")

            VStack(alignment: .trailing, spacing: 4) {
                statusView
                HStack(spacing: 6) {
                    Text(model.sizeLabel).font(.caption).foregroundStyle(.secondary)
                    actionButton
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusView: some View {
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
                ProgressView(value: fraction).frame(width: 120)
            }
        case .preparing:
            HStack(spacing: 6) {
                Text(SettingsStrings.localModelPreparing).font(.caption).foregroundStyle(.secondary)
                ProgressView().controlSize(.small)
            }
        case .ready:
            Text("● \(readyText)")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Text(SettingsStrings.localModelFailed(message))
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    private var readyText: String {
        guard let pending = selection.pending, pending != model.id,
              let pendingModel = models.models.first(where: { $0.id == pending })
        else { return SettingsStrings.localModelReady }
        return SettingsStrings.localModelInUseUntil(pendingModel.displayName)
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status {
        case .downloading, .preparing:
            Button(SettingsStrings.localModelCancel) { models.cancel() }
                .controlSize(.small)
                .accessibilityIdentifier("settings.localModel.\(model.id).cancel")
        case .downloaded, .ready:
            deleteButton
        case .failed where selection.hasFiles(model.id):
            // Its files stay after a failure; deleting them forces a new download.
            deleteButton
        case .notDownloaded, .failed:
            EmptyView()
        }
    }

    private var deleteButton: some View {
        Button(SettingsStrings.localModelDelete) { models.delete(model.id) }
            .controlSize(.small)
            .disabled(isBusy)
            .accessibilityIdentifier("settings.localModel.\(model.id).delete")
    }
}
