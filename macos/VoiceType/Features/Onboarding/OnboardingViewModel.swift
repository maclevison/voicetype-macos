import Core
import Foundation
import Observation

/// One opening of the onboarding window: walks the steps, keeps the practice
/// fields' text and tells the `OnboardingPracticeSink` which practice step is
/// on screen. Only the `Paster` (or the user) writes into a field; a paste is
/// confirmed against the field before the step is marked.
@MainActor @Observable
final class OnboardingViewModel {
    private(set) var flow = OnboardingFlow()
    /// Bound to each practice step's TextEditor.
    var practiceText: [OnboardingStep: String] = [:]
    /// The last take on the Translation step came out untranslated; cleared by a translated one.
    private(set) var translationFellBack = false

    @ObservationIgnored private let snapshot: ConfigStoreSnapshot
    @ObservationIgnored private let sink: OnboardingPracticeSink
    @ObservationIgnored private let session: UUID

    init(snapshot: ConfigStoreSnapshot, sink: OnboardingPracticeSink) {
        self.snapshot = snapshot
        self.sink = sink
        session = sink.beginSession()
        sink.visibleStep = flow.current
        sink.onPasted = { [weak self] paste in self?.confirmPaste(paste) }
    }

    func next() {
        flow.next()
        sink.visibleStep = flow.current
    }

    func back() {
        flow.back()
        sink.visibleStep = flow.current
    }

    func windowKeyChanged(_ isKey: Bool) {
        sink.isKey = isKey
    }

    /// Marks the step only if the pasted text really is in its field.
    func confirmPaste(_ paste: OnboardingPaste) {
        guard !paste.text.isEmpty, practiceText[paste.step, default: ""].contains(paste.text) else { return }
        if paste.step == .translation { translationFellBack = paste.take.translationFellBack }
        flow.record(paste.take, on: paste.step)
    }

    func fieldIdentifier(for step: OnboardingStep) -> String {
        OnboardingPracticeTicket.fieldIdentifier(session: session, step: step)
    }

    func finish() async {
        guard !snapshot.config.onboardingCompleted else { return }
        await snapshot.update { $0.onboardingCompleted = true }
    }

    /// Closing counts as seen. A session another opening already replaced is left alone.
    func windowClosed() async {
        if sink.session == session { sink.endSession() }
        await finish()
    }
}
