import Core
import XCTest
@testable import VoiceType

@MainActor
final class OnboardingViewModelTests: XCTestCase {

    private let plainTake = OnboardingTake(translated: false, handsFree: false)

    private func makeVM(seed: AppConfig = AppConfig(),
                        sink: OnboardingPracticeSink? = nil) async throws -> (OnboardingViewModel, OnboardingPracticeSink, ConfigStoreSnapshot) {
        let sink = sink ?? OnboardingPracticeSink()
        let snapshot = try await SettingsTestSupport.makeSnapshot(seed: seed)
        return (OnboardingViewModel(snapshot: snapshot, sink: sink), sink, snapshot)
    }

    func testAcceptingStepFollowsKeyAndPracticeSteps() async throws {
        let (vm, sink, _) = try await makeVM()
        vm.windowKeyChanged(true)
        XCTAssertNil(sink.acceptingStep)

        vm.next()
        XCTAssertEqual(sink.acceptingStep, .dictation)
        vm.windowKeyChanged(false)
        XCTAssertNil(sink.acceptingStep)
        vm.windowKeyChanged(true)
        XCTAssertEqual(sink.acceptingStep, .dictation)

        vm.next(); vm.next(); vm.next()
        XCTAssertEqual(vm.flow.current, .voiceNote)
        XCTAssertNil(sink.acceptingStep)

        vm.back()
        XCTAssertEqual(sink.acceptingStep, .translation)
    }

    func testPasteMarksStepOnlyWhenTextIsInTheField() async throws {
        let (vm, sink, _) = try await makeVM()
        vm.practiceText[.dictation] = "antes olá mundo"
        sink.pasted(OnboardingPaste(step: .dictation, text: "olá mundo", take: plainTake))
        XCTAssertTrue(vm.flow.isPracticed(.dictation))
        XCTAssertEqual(vm.practiceText[.dictation], "antes olá mundo")

        let (empty, emptySink, _) = try await makeVM()
        emptySink.pasted(OnboardingPaste(step: .dictation, text: "olá mundo", take: plainTake))
        XCTAssertFalse(empty.flow.isPracticed(.dictation))
        XCTAssertEqual(empty.practiceText[.dictation, default: ""], "")
    }

    func testHandsFreePasteWithoutLockDoesNotMark() async throws {
        let (vm, sink, _) = try await makeVM()
        vm.practiceText[.handsFree] = "olá mundo"
        sink.pasted(OnboardingPaste(step: .handsFree, text: "olá mundo", take: plainTake))
        XCTAssertFalse(vm.flow.isPracticed(.handsFree))

        sink.pasted(OnboardingPaste(step: .handsFree, text: "olá mundo",
                                    take: OnboardingTake(translated: false, handsFree: true)))
        XCTAssertTrue(vm.flow.isPracticed(.handsFree))
    }

    func testFinishPersistsCompleted() async throws {
        var seed = AppConfig()
        seed.onboardingCompleted = false
        let (vm, _, snapshot) = try await makeVM(seed: seed)
        await vm.finish()
        XCTAssertTrue(snapshot.config.onboardingCompleted)
    }

    func testWindowClosedStopsAcceptingAndPersists() async throws {
        let (vm, sink, snapshot) = try await makeVM()
        vm.next()
        vm.windowKeyChanged(true)
        let ticket = try XCTUnwrap(sink.ticket())

        await vm.windowClosed()

        XCTAssertNil(sink.session)
        XCTAssertNil(sink.acceptingStep)
        XCTAssertNil(sink.onPasted)
        XCTAssertFalse(sink.isValid(ticket))
        XCTAssertTrue(snapshot.config.onboardingCompleted)
    }

    func testEachViewModelStartsANewSession() async throws {
        let sink = OnboardingPracticeSink()
        let (first, _, _) = try await makeVM(sink: sink)
        let firstSession = try XCTUnwrap(sink.session)
        first.next()
        first.windowKeyChanged(true)
        let firstTicket = try XCTUnwrap(sink.ticket())

        let (second, _, _) = try await makeVM(sink: sink)
        let secondSession = try XCTUnwrap(sink.session)
        second.next()
        second.windowKeyChanged(true)

        XCTAssertNotEqual(firstSession, secondSession)
        XCTAssertFalse(sink.isValid(firstTicket))
        XCTAssertNotEqual(first.fieldIdentifier(for: .dictation), second.fieldIdentifier(for: .dictation))
    }

    func testFellBackTranslationShowsNoticeAndDoesNotMark() async throws {
        let (vm, sink, _) = try await makeVM()
        vm.practiceText[.translation] = "olá mundo"
        sink.pasted(OnboardingPaste(step: .translation, text: "olá mundo",
                                    take: OnboardingTake(translated: false, handsFree: false, translationFellBack: true)))
        XCTAssertTrue(vm.translationFellBack)
        XCTAssertFalse(vm.flow.isPracticed(.translation))

        vm.practiceText[.translation] = "olá mundo hello world"
        sink.pasted(OnboardingPaste(step: .translation, text: "hello world",
                                    take: OnboardingTake(translated: true, handsFree: false)))
        XCTAssertFalse(vm.translationFellBack)
        XCTAssertTrue(vm.flow.isPracticed(.translation))
    }

    func testFieldIdentifierMatchesTheTicket() async throws {
        let (vm, sink, _) = try await makeVM()
        vm.next()
        vm.windowKeyChanged(true)
        XCTAssertEqual(vm.fieldIdentifier(for: .dictation), sink.ticket()?.fieldIdentifier)
    }
}
