import Core
import Foundation
import Observation

/// One practice take's destination: the onboarding session (one per window
/// opening) and the step shown at press time. Closing, reopening or changing
/// step invalidates it.
struct OnboardingPracticeTicket: Equatable, Sendable {
    let session: UUID
    let step: OnboardingStep

    /// AXIdentifier of this session's and this step's practice TextEditor; no
    /// other editor has it.
    var fieldIdentifier: String { Self.fieldIdentifier(session: session, step: step) }

    static func fieldIdentifier(session: UUID, step: OnboardingStep) -> String {
        "onboarding.practice.\(session.uuidString).\(step.rawValue)"
    }
}

/// A practice take that landed in the onboarding field.
struct OnboardingPaste: Equatable {
    let step: OnboardingStep
    let text: String
    let take: OnboardingTake
}

/// Tells the `RecordingOrchestrator` which practice step the onboarding window
/// shows as key window, and hands confirmed pastes back to the window. It never
/// writes into the field: the text only gets there through the `Paster`.
@MainActor @Observable
final class OnboardingPracticeSink {
    /// One per window opening; nil while the window is closed.
    private(set) var session: UUID?
    /// The step the window shows now.
    var visibleStep: OnboardingStep?
    /// The onboarding window is the key window.
    var isKey = false
    @ObservationIgnored var onPasted: ((OnboardingPaste) -> Void)?

    var acceptingStep: OnboardingStep? {
        guard session != nil, isKey, let visibleStep, visibleStep.isPractice else { return nil }
        return visibleStep
    }

    @discardableResult
    func beginSession() -> UUID {
        let id = UUID()
        session = id
        return id
    }

    func endSession() {
        session = nil
        visibleStep = nil
        isKey = false
        onPasted = nil
    }

    func ticket() -> OnboardingPracticeTicket? {
        guard let session, let step = acceptingStep else { return nil }
        return OnboardingPracticeTicket(session: session, step: step)
    }

    /// Same session and same step on screen. Losing key status mid-take does
    /// not invalidate it: the Paster's field check is what guards the paste.
    func isValid(_ ticket: OnboardingPracticeTicket) -> Bool {
        session == ticket.session && visibleStep == ticket.step
    }

    func pasted(_ paste: OnboardingPaste) {
        onPasted?(paste)
    }
}
