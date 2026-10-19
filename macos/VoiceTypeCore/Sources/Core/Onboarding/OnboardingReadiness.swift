import Foundation

// What keeps a practice step from working, in the order the step lists them.
public enum OnboardingBlocker: Equatable, Sendable {
    case accessibility, microphone, groqKeyMissing, localModelNotReady, translateDisabled, translatorUnavailable, handsFreeDisabled
}

// Apple Intelligence as the translator sees it; below macOS 26 it is `.unsupportedOS`.
public enum AppleIntelligenceState: Equatable, Sendable { case unsupportedOS, unavailable, available }

// Which blockers each practice step shows before the user tries it. The engine
// rules mirror the orchestrator's `preflight` and `defaultPipelineFactory`, so a
// step only warns about what would really make its take fail or come out raw.
public enum OnboardingReadiness {
    public static func blockers(for step: OnboardingStep, config: AppConfig,
                                microphoneGranted: Bool, accessibilityGranted: Bool,
                                localModelReady: Bool,
                                appleIntelligence: AppleIntelligenceState,
                                appleTranslationInstalled: Bool) -> [OnboardingBlocker] {
        guard step.isPractice else { return [] }
        let hasKey = !config.groq.apiKey.isEmpty
        var blockers: [OnboardingBlocker] = []

        if !accessibilityGranted { blockers.append(.accessibility) }
        if !microphoneGranted { blockers.append(.microphone) }

        switch config.transcriptionEngine {
        case "groq":
            if !hasKey { blockers.append(.groqKeyMissing) }
        case "local":
            if !localModelReady { blockers.append(.localModelNotReady) }
        default:
            if !hasKey && !localModelReady { blockers.append(.localModelNotReady) }
        }

        if step == .translation {
            if !config.translate.enabled {
                blockers.append(.translateDisabled)
            } else if !translatorAvailable(config.translateEngine, hasKey: hasKey, appleIntelligence: appleIntelligence,
                                           appleTranslationInstalled: appleTranslationInstalled) {
                blockers.append(.translatorUnavailable)
            }
        }

        if step == .handsFree && !config.handsFreeEnabled { blockers.append(.handsFreeDisabled) }
        return blockers
    }

    // Mirrors `TranslatePlan`. Below macOS 26 translation is always Groq. On
    // device means Apple Intelligence or, without it, the Translation framework
    // with the dictation→target pair installed. "groq" needs the key, "local"
    // needs on-device, auto needs either.
    private static func translatorAvailable(_ engine: String, hasKey: Bool,
                                            appleIntelligence: AppleIntelligenceState,
                                            appleTranslationInstalled: Bool) -> Bool {
        if appleIntelligence == .unsupportedOS { return hasKey }
        let onDevice = appleIntelligence == .available || appleTranslationInstalled
        switch engine {
        case "groq":  return hasKey
        case "local": return onDevice
        default:      return hasKey || onDevice
        }
    }
}
