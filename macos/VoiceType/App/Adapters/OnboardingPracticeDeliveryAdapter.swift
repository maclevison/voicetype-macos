import AppKit
import Core
import Foundation

enum OnboardingPracticeError: Error, Equatable {
    /// The practice window closed, reopened or changed step before delivery.
    case destinationGone
}

/// Delivers a practice take through the real `Paster` into VoiceType itself,
/// but only into the onboarding editor of the ticket's session and step
/// (`requiredField`). The sink hears about it only after a paste without error.
/// A refused delivery still gets its one history entry here, since
/// `RunPipelineUseCase` records only after a successful paste.
struct OnboardingPracticeDeliveryAdapter: PasterDelivery {
    let paster: Paster
    /// `FocusedApp.ownApp()`.
    let target: FrontmostAppSnapshot
    let sink: OnboardingPracticeSink
    let ticket: OnboardingPracticeTicket
    let translationRequested: Bool
    /// The take was locked (hands-free).
    let handsFree: Bool
    /// `RawFallbackTranslate` hands back the raw transcript when translation
    /// fails, silently: pasted text equal to it means nothing was translated.
    let rawTranscript: @Sendable () async -> String?
    /// Nil when `cfg.history.enabled` is off.
    let history: HistoryRecorder?

    func paste(text: String, targetBundleId: String, autoEnter: Bool) async throws {
        do {
            guard await sink.isValid(ticket) else {
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                throw OnboardingPracticeError.destinationGone
            }
            try await paster.paste(
                text: text,
                target: target,
                autoEnter: autoEnter,
                requiredField: FocusedField(pid: target.processIdentifier, identifier: ticket.fieldIdentifier)
            )
        } catch {
            if !(error is CancellationError), (error as? PipelineError) != .cancelled {
                await history?.record(HistoryEntry(
                    mode: translationRequested ? .translate : .refine,
                    sourceApp: targetBundleId,
                    text: text
                ))
            }
            throw error
        }

        let raw = await rawTranscript()
        let translated = translationRequested && text != raw
        let take = OnboardingTake(
            translated: translated,
            handsFree: handsFree,
            translationFellBack: translationRequested && !translated
        )
        await sink.pasted(OnboardingPaste(step: ticket.step, text: text, take: take))
    }
}
