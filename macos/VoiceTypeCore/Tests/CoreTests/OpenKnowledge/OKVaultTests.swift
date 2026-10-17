import Foundation
import Testing
@testable import Core

@Suite("OKVault")
struct OKVaultTests {

    @Test func detectsProjectRootByDotOkDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        #expect(!OKVault.isProjectRoot(root))

        let marker = root.appendingPathComponent(".ok")
        try Data().write(to: marker)
        #expect(!OKVault.isProjectRoot(root))

        try fm.removeItem(at: marker)
        try fm.createDirectory(at: marker, withIntermediateDirectories: false)
        #expect(OKVault.isProjectRoot(root))
    }

    @Test func identityDistinguishesRecreatedAndOtherVaults() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let a = base.appendingPathComponent("A", isDirectory: true)
        let b = base.appendingPathComponent("B", isDirectory: true)
        for vault in [a, b] { try fm.createDirectory(at: vault.appendingPathComponent(".ok"), withIntermediateDirectories: true) }

        let identity = try OKVaultIdentity.of(a)
        #expect(identity.matches(a))
        #expect(!identity.matches(b))

        let link = base.appendingPathComponent("L")
        try fm.createSymbolicLink(at: link, withDestinationURL: a)
        #expect(try OKVaultIdentity.of(link) == identity)
        #expect(identity.matches(link))

        let decoded = try JSONDecoder().decode(OKVaultIdentity.self, from: JSONEncoder().encode(identity))
        #expect(decoded == identity)

        try fm.removeItem(at: a)
        #expect(!identity.matches(a))
        #expect(throws: (any Error).self) { try OKVaultIdentity.of(a) }
        try fm.createDirectory(at: a.appendingPathComponent(".ok"), withIntermediateDirectories: true)
        #expect(!identity.matches(a))
        #expect(try OKVaultIdentity.of(a).root == identity.root)
    }

    @Test func urlExpandsTildeAsDirectory() {
        let url = OKVault.url("~/Vault")
        #expect(url.path == (NSHomeDirectory() as NSString).appendingPathComponent("Vault"))
        #expect(url.hasDirectoryPath)
        #expect(OKVault.url("/tmp/MB").path == "/tmp/MB")
    }

    @Test func blankPathIsUnsetAndNeverAProjectRoot() {
        for path in ["", "  ", "\n"] {
            #expect(!OKVault.isConfigured(path))
            #expect(OKVault.url(path) == OKVault.unset)
        }
        #expect(!OKVault.isProjectRoot(OKVault.unset))
        #expect(OKVault.isConfigured("~/Vault"))
    }
}
