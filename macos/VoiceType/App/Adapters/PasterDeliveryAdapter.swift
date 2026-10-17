import AppKit
import Core
import Foundation
import OSLog

// Bridges the AppKit-aware `Paster` to the Sendable `Core.PasterDelivery`
// use-case protocol. `Paster` paste-targets are `FrontmostAppSnapshot`, but
// use cases only see bundle identifiers; the orchestrator captures the
// snapshot at press time and supplies it through `lookupTarget`.
struct PasterDeliveryAdapter: PasterDelivery {
    let paster: Paster
    let lookupTarget: @Sendable (String) -> FrontmostAppSnapshot?
    /// Fires after a successful paste with the exact text pasted (#50).
    var onPasted: (@Sendable (String) -> Void)? = nil

    func paste(text: String, targetBundleId: String, autoEnter: Bool) async throws {
        guard let snapshot = lookupTarget(targetBundleId) else {
            throw PasterError.targetAppNotRunning
        }
        try await paster.paste(text: text, target: snapshot, autoEnter: autoEnter)
        onPasted?(text)
    }
}

/// #79 voice note: the idea goes through the assistant CLI (fixes ASR errors,
/// adds title + tags) into its own note under `Ideas/`, and today's daily note
/// gets a `- HH:mm [[note|Título]]` link. If the CLI is missing/fails/times out,
/// the refined text goes straight into the daily (the pre-assistant behavior).
/// In OpenKnowledge mode both land in the vault's `_inbox/` (`OKInbox`).
/// On a write failure the text goes to the clipboard so the idea isn't lost.
struct DailyNoteDeliveryAdapter: PasterDelivery {
    struct WriteFailed: Error {
        let detail: String
    }

    private static let log = Logger(subsystem: "VoiceType", category: "VoiceNote")

    let vault: URL
    /// `AppConfig.meetingVaultKind`: Obsidian folder or OpenKnowledge `_inbox/`.
    let kind: MeetingVaultKind
    /// `AppConfig.claudeCLIPath` (nil = default install locations).
    let cliPath: String?
    /// Raw ASR of this take, kept in the idea note as "Transcrição original".
    let rawTranscript: @Sendable () async -> String?
    /// After a successful save: the idea's title, or nil when it went to the daily untitled.
    let onSaved: @Sendable (String?) async -> Void

    func paste(text: String, targetBundleId: String, autoEnter: Bool) async throws {
        let date = Date()
        let idea = await polish(text, original: await rawTranscript() ?? text, at: date)
        do {
            switch kind {
            case .obsidian:
                if let idea {
                    let note = try idea.write(to: vault)
                    try DailyNote.append(DailyNote.link(to: note, title: idea.title), at: date, to: vault)
                } else {
                    try DailyNote.append(text, at: date, to: vault)
                }
            case .openKnowledge:
                guard OKVault.isProjectRoot(vault) else {
                    throw WriteFailed(detail: vault == OKVault.unset
                        ? "Nenhum vault OpenKnowledge configurado em Ajustes → Reuniões."
                        : "Vault OpenKnowledge inválido: \(vault.path)")
                }
                if let idea {
                    let note = try OKInbox.writeIdea(idea, to: vault)
                    try OKInbox.appendToDaily(OKInbox.link(toIdea: note, title: idea.title, vault: vault), at: date, to: vault)
                } else {
                    try OKInbox.appendToDaily(text, at: date, to: vault)
                }
            }
        } catch {
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            throw error as? WriteFailed ?? WriteFailed(detail: error.localizedDescription)
        }
        await onSaved(idea?.title)
    }

    /// Nil on any failure — the caller falls back to the untitled daily entry.
    private func polish(_ text: String, original: String, at date: Date) async -> IdeaNote? {
        guard let cli = ClaudeCLISummarizer.locate(configured: cliPath) else {
            Self.log.info("assistant CLI not found; idea saved untitled")
            return nil
        }
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Revisando ideia ditada")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        do {
            return try await ClaudeCLISummarizer(executableURL: cli, timeoutSeconds: 60)
                .polishIdea(text, original: original, at: date)
        } catch let error as ClaudeCLISummarizer.CLIError {
            Self.log.error("idea polish failed: \(error.reason, privacy: .public)")
        } catch {
            Self.log.error("idea polish failed: \(String(describing: error), privacy: .public)")
        }
        return nil
    }
}
