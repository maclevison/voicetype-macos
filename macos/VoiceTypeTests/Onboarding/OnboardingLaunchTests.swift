import Core
import XCTest
@testable import VoiceType

final class OnboardingLaunchTests: XCTestCase {

    func testOpensWhenNotCompleted() {
        XCTAssertTrue(OnboardingLaunch.shouldAutoOpen(completed: false, environment: [:], arguments: []))
    }

    func testStaysClosedWhenCompleted() {
        XCTAssertFalse(OnboardingLaunch.shouldAutoOpen(completed: true, environment: [:], arguments: []))
    }

    func testTestHostNeverOpens() {
        XCTAssertFalse(OnboardingLaunch.shouldAutoOpen(completed: false,
                                                       environment: ["XCTestConfigurationFilePath": "/x"],
                                                       arguments: []))
    }

    func testSkipArgumentNeverOpens() {
        XCTAssertFalse(OnboardingLaunch.shouldAutoOpen(completed: false,
                                                       environment: [:],
                                                       arguments: ["VoiceType", "--skip-onboarding"]))
    }

    func testDecisionReadsTheStoreNotTheDefault() async throws {
        var done = AppConfig()
        done.onboardingCompleted = true
        let doneStore = try await SettingsTestSupport.makeInMemoryStore(seed: done)
        let opensDone = await OnboardingLaunch.shouldAutoOpen(store: doneStore, environment: [:], arguments: [])
        XCTAssertFalse(opensDone)

        let pendingStore = try await SettingsTestSupport.makeInMemoryStore(seed: AppConfig())
        let opensPending = await OnboardingLaunch.shouldAutoOpen(store: pendingStore, environment: [:], arguments: [])
        XCTAssertTrue(opensPending)
    }
}
