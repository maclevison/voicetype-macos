import XCTest

final class SettingsSceneUITests: XCTestCase {

    func testSettingsRendersAllSidebarSections() throws {
        let app = XCUIApplication()
        // The onboarding would open by itself on a fresh config and become
        // `windows.firstMatch`.
        app.launchArguments = ["--skip-onboarding"]
        app.launch()
        // Trigger ⌘, to open Settings. The app is .accessory so the Settings
        // scene becomes the only visible window.
        app.activate()
        app.typeKey(",", modifierFlags: .command)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        for label in ["Histórico", "Geral", "Atalhos", "Áudio", "Armazenamento", "Inicialização", "Sobre"] {
            let item = window.staticTexts[label].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 3), "Sidebar item missing: \(label)")
        }
    }

    func testGeneralSectionTestKeyShowsInvalidStatus() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-stub-groq-401", "--skip-onboarding"]
        app.launch()
        app.activate()
        app.typeKey(",", modifierFlags: .command)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let field = window.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.click()
        field.typeText("gsk_bad")

        window.buttons[SettingsCopy.testButton].firstMatch.click()

        let status = window.staticTexts["Inválida (status 401)"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
    }
}

// Local mirror of pt-BR copy needed by UITests. We can't import the App target
// from the UITests bundle, so duplicate the literals here. Keep in sync with
// `SettingsStrings`.
private enum SettingsCopy {
    static let testButton = "Testar chave"
}
