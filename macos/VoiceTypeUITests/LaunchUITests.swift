import XCTest

final class LaunchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_appLaunchesAndStaysRunning() {
        let app = XCUIApplication()
        // The onboarding would open by itself on a fresh config.
        app.launchArguments = ["--skip-onboarding"]
        app.launch()

        // Menu-bar-only apps (LSUIElement) typically settle into .runningBackground
        // because they don't have a focused window. Accept either running state.
        XCTAssertTrue(
            app.state == .runningForeground || app.state == .runningBackground,
            "Expected app to be running; got state rawValue=\(app.state.rawValue)"
        )

        // Give the run loop a moment so any deferred crash would surface.
        let stillUp = expectation(description: "app still running")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if app.state == .runningForeground || app.state == .runningBackground {
                stillUp.fulfill()
            }
        }
        wait(for: [stillUp], timeout: 3.0)

        app.terminate()
    }
}
