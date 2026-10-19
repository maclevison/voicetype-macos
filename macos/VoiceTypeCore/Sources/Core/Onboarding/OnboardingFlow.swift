import Foundation

// The onboarding window's steps, in the order they are shown. Only dictation,
// hands-free and translation ask for a real take; the rest are explanation.
public enum OnboardingStep: Int, CaseIterable, Sendable {
    case prepare, dictation, handsFree, translation, voiceNote, history, meetings, personalize

    public var isPractice: Bool {
        switch self {
        case .dictation, .handsFree, .translation: return true
        default: return false
        }
    }

    /// Whether `take` counts as practicing this step. A translation that fell back
    /// to the raw transcript counts neither as translation nor as plain dictation.
    public func accepts(_ take: OnboardingTake) -> Bool {
        switch self {
        case .dictation:   return !take.translated && !take.translationFellBack
        case .handsFree:   return take.handsFree
        case .translation: return take.translated
        default:           return false
        }
    }
}

// What a practice take delivered to the onboarding field.
public struct OnboardingTake: Equatable, Sendable {
    /// The translation really happened (pasted text ≠ raw transcript).
    public let translated: Bool
    public let handsFree: Bool
    /// Translation was asked for, but the text came out raw (RawFallbackTranslate).
    public let translationFellBack: Bool

    public init(translated: Bool, handsFree: Bool, translationFellBack: Bool = false) {
        self.translated = translated
        self.handsFree = handsFree
        self.translationFellBack = translationFellBack
    }
}

// Pure step navigation plus which practice steps were done. Progress is never
// persisted: reopening the window starts from `.prepare`.
public struct OnboardingFlow: Equatable, Sendable {
    public private(set) var current: OnboardingStep = .prepare
    private var practiced: Set<OnboardingStep> = []

    public init() {}

    /// 1-based.
    public var position: Int { current.rawValue + 1 }
    public var total: Int { OnboardingStep.allCases.count }
    public var progress: Double { Double(position) / Double(total) }
    public var canGoBack: Bool { current != .prepare }
    public var isLast: Bool { current == .personalize }

    public mutating func next() {
        guard let step = OnboardingStep(rawValue: current.rawValue + 1) else { return }
        current = step
    }

    public mutating func back() {
        guard let step = OnboardingStep(rawValue: current.rawValue - 1) else { return }
        current = step
    }

    /// Marks `step` as practiced when it accepts `take`; true only the first time.
    @discardableResult
    public mutating func record(_ take: OnboardingTake, on step: OnboardingStep) -> Bool {
        guard step.accepts(take) else { return false }
        return practiced.insert(step).inserted
    }

    public func isPracticed(_ step: OnboardingStep) -> Bool {
        practiced.contains(step)
    }
}
