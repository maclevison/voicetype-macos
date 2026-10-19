import Foundation

// A translator the dictation pipeline can call. `appleTranslation` is Apple's
// Translation framework (on-device, installed language pairs only).
public enum TranslateStep: Equatable, Sendable {
    case appleIntelligence, appleTranslation, groq
}

// Which translators a take tries, in order, before `RawFallbackTranslate`
// pastes the raw text. On macOS 26+ (the caller's gate) the on-device
// translator is Apple Intelligence when it is up, else the Translation
// framework. "groq" stays Groq only, "local" stays on-device only, and auto
// tries on-device first, then Groq.
public enum TranslatePlan {
    public static func steps(engine: String, appleIntelligence: Bool) -> [TranslateStep] {
        let onDevice: TranslateStep = appleIntelligence ? .appleIntelligence : .appleTranslation
        switch engine {
        case "groq":  return [.groq]
        case "local": return [onDevice]
        default:      return [onDevice, .groq]
        }
    }
}
