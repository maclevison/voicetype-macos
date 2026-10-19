import Testing
@testable import Core

@Suite("TranslatePlan")
struct TranslatePlanTests {
    @Test func autoTriesOnDeviceThenGroq() {
        #expect(TranslatePlan.steps(engine: "auto", appleIntelligence: true) == [.appleIntelligence, .groq])
        #expect(TranslatePlan.steps(engine: "auto", appleIntelligence: false) == [.appleTranslation, .groq])
    }

    @Test func localStaysOnDevice() {
        #expect(TranslatePlan.steps(engine: "local", appleIntelligence: true) == [.appleIntelligence])
        #expect(TranslatePlan.steps(engine: "local", appleIntelligence: false) == [.appleTranslation])
    }

    @Test func groqStaysGroq() {
        #expect(TranslatePlan.steps(engine: "groq", appleIntelligence: true) == [.groq])
        #expect(TranslatePlan.steps(engine: "groq", appleIntelligence: false) == [.groq])
    }

    @Test func unknownEngineBehavesLikeAuto() {
        #expect(TranslatePlan.steps(engine: "", appleIntelligence: false) == [.appleTranslation, .groq])
    }
}
