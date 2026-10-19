import Testing
@testable import Core

@Suite("LocalModelCatalog")
struct LocalModelCatalogTests {
    @Test func exactCatalog() {
        #expect(LocalModelCatalog.all.map(\.id) == ["openai_whisper-small", "openai_whisper-large-v3-v20240930_turbo_632MB", "parakeet-ultra"])
        #expect(LocalModelCatalog.defaultID == "openai_whisper-small")
        #expect(LocalModelCatalog.model(id: "parakeet-ultra")?.engine == .parakeet)
        #expect(LocalModelCatalog.model(id: "parakeet-ultra")?.supportsVocabulary == false)
        #expect(LocalModelCatalog.model(id: "openai_whisper-small")?.supportsVocabulary == true)
        #expect(LocalModelCatalog.model(id: "openai_whisper-large-v3-v20240930_turbo_632MB")?.supportsVocabulary == true)
        #expect(LocalModelCatalog.model(id: "nope") == nil)
    }

    @Test func parakeetHiddenOnMacOS14() {
        #expect(!LocalModelCatalog.available(macOSMajor: 14).map(\.id).contains("parakeet-ultra"))
        #expect(LocalModelCatalog.available(macOSMajor: 15).count == 3)
    }
}
