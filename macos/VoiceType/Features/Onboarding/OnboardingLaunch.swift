import Core
import Foundation

/// Whether the onboarding window opens by itself at launch: only while
/// `onboardingCompleted` is `false`, never in the unit-test host and never
/// when UI tests pass `--skip-onboarding`.
enum OnboardingLaunch {
    static let skipArgument = "--skip-onboarding"

    static func shouldAutoOpen(completed: Bool, environment: [String: String], arguments: [String]) -> Bool {
        if completed { return false }
        if environment["XCTestConfigurationFilePath"] != nil { return false }
        if arguments.contains(skipArgument) { return false }
        return true
    }

    /// Reads the store, not `ConfigStoreSnapshot.config`: the snapshot starts at
    /// `AppConfig()` (not completed) until its initial load lands, which would
    /// open the window on every launch. A read error keeps the window closed.
    static func shouldAutoOpen(store: ConfigStore,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               arguments: [String] = ProcessInfo.processInfo.arguments) async -> Bool {
        guard let config = try? await store.load() else { return false }
        return shouldAutoOpen(completed: config.onboardingCompleted, environment: environment, arguments: arguments)
    }
}
