import Foundation
import Testing
@testable import Core

@Suite("OKSlug")
struct OKSlugTests {

    @Test func slugFoldsAccentsAndFallsBack() {
        #expect(OKSlug.make(from: "Revisão de Ação — Sprint 12") == "revisao-de-acao-sprint-12")
        #expect(OKSlug.make(from: "✨✨") == "" && OKSlug.make(from: "!!!") == "")
        #expect(OKSlug.make(from: String(repeating: "abc ", count: 40)).count <= 60)
        #expect(!OKSlug.make(from: String(repeating: "abc ", count: 40)).hasSuffix("-"))
        #expect(OKSlug.isValid("p5") && OKSlug.isValid("billing-api"))
        #expect(!OKSlug.isValid("Billing") && !OKSlug.isValid("a--b") && !OKSlug.isValid("-a") && !OKSlug.isValid("ação"))
    }

    @Test func validSlugsAreAtMostEightyChars() {
        #expect(OKSlug.isValid(String(repeating: "a", count: 80)))
        #expect(!OKSlug.isValid(String(repeating: "a", count: 81)))
        #expect(!OKSlug.isValid("") && !OKSlug.isValid("a-") && !OKSlug.isValid("a b"))
    }
}
