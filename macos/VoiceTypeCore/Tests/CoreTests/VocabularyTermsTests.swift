import Testing
@testable import Core

@Suite("VocabularyTerms")
struct VocabularyTermsTests {
    @Test func splitsOnCommaAndNewlineTrimmingEmpties() {
        #expect(VocabularyTerms.parse(" Redis, ConfigStore\n\nasync await ,") == ["Redis", "ConfigStore", "async await"])
        #expect(VocabularyTerms.parse("") == [])
    }
}
