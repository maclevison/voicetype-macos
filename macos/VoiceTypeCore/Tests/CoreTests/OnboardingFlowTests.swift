import Testing
@testable import Core

@Suite("OnboardingFlow")
struct OnboardingFlowTests {

    @Test func startsAtPrepareWithEightSteps() {
        let flow = OnboardingFlow()
        #expect(flow.current == .prepare)
        #expect(flow.position == 1)
        #expect(flow.total == 8)
        #expect(flow.canGoBack == false)
    }

    @Test func nextAndBackWalkTheStepsInOrder() {
        var flow = OnboardingFlow()
        var visited: [OnboardingStep] = [flow.current]
        for _ in 0..<7 {
            flow.next()
            visited.append(flow.current)
        }
        #expect(visited == OnboardingStep.allCases)
        #expect(flow.current == .personalize)
        #expect(flow.isLast)
        #expect(flow.progress == 1.0)

        flow.next()
        #expect(flow.current == .personalize)
        #expect(flow.position == 8)

        flow.back()
        #expect(flow.current == .meetings)
        #expect(flow.isLast == false)
    }

    @Test func backOnTheFirstStepIsANoOp() {
        var flow = OnboardingFlow()
        flow.back()
        #expect(flow.current == .prepare)
    }

    @Test func dictationAcceptsAnyUntranslatedTake() {
        var flow = OnboardingFlow()
        #expect(flow.record(OnboardingTake(translated: true, handsFree: false), on: .dictation) == false)
        #expect(flow.isPracticed(.dictation) == false)
        #expect(flow.record(OnboardingTake(translated: false, handsFree: false), on: .dictation) == true)
        #expect(flow.isPracticed(.dictation))
    }

    @Test func handsFreeStepNeedsALockedTake() {
        var flow = OnboardingFlow()
        #expect(flow.record(OnboardingTake(translated: false, handsFree: false), on: .handsFree) == false)
        #expect(flow.isPracticed(.handsFree) == false)
        #expect(flow.record(OnboardingTake(translated: false, handsFree: true), on: .handsFree) == true)
        #expect(flow.isPracticed(.handsFree))
    }

    @Test func translationNeedsATranslatedTake() {
        var flow = OnboardingFlow()
        let fellBack = OnboardingTake(translated: false, handsFree: false, translationFellBack: true)
        #expect(flow.record(fellBack, on: .translation) == false)
        #expect(flow.isPracticed(.translation) == false)
        #expect(flow.record(OnboardingTake(translated: true, handsFree: false), on: .translation) == true)
        #expect(flow.isPracticed(.translation))
    }

    @Test func fellBackTranslationDoesNotCountAsDictation() {
        var flow = OnboardingFlow()
        let fellBack = OnboardingTake(translated: false, handsFree: false, translationFellBack: true)
        #expect(flow.record(fellBack, on: .dictation) == false)
        #expect(flow.isPracticed(.dictation) == false)
    }

    @Test func explanationStepsNeverRecord() {
        var flow = OnboardingFlow()
        let takes = [
            OnboardingTake(translated: false, handsFree: false),
            OnboardingTake(translated: true, handsFree: false),
            OnboardingTake(translated: false, handsFree: true),
            OnboardingTake(translated: false, handsFree: false, translationFellBack: true),
        ]
        for step in [OnboardingStep.voiceNote, .history, .prepare] {
            #expect(step.isPractice == false)
            for take in takes {
                #expect(flow.record(take, on: step) == false, "\(step)")
            }
            #expect(flow.isPracticed(step) == false)
        }
    }

    @Test func recordingTwiceReportsOnlyTheFirst() {
        var flow = OnboardingFlow()
        let take = OnboardingTake(translated: false, handsFree: false)
        #expect(flow.record(take, on: .dictation) == true)
        #expect(flow.record(take, on: .dictation) == false)
        #expect(flow.isPracticed(.dictation))
    }

    @Test func onlyTheThreePracticeStepsArePractice() {
        let practice = OnboardingStep.allCases.filter(\.isPractice)
        #expect(practice == [.dictation, .handsFree, .translation])
    }
}
