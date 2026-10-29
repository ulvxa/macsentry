import Foundation
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct PrivateKeyProtectionTests {
    private static let keyPaths = [
        ".ollama/id_ed25519", ".ollama/id_ed25519.pub", "Library/Application Support/Tool/id_rsa",
        "Library/Application Support/Tool/keys/id_ecdsa_sk", "Documents/certs/server.pem", "Downloads/identity.p12",
        "Library/Application Support/Tool/tls/client.KEY",
    ]

    private static func policy(_ fixture: FixtureBuilder) throws -> DefaultProtectionPolicy {
        try DefaultProtectionPolicy(
            homeURL: fixture.root,
            databaseURL: fixture.url("Library/Application Support/MacSentry/macsentry.sqlite"),
        )
    }

    @Test(arguments: keyPaths)
    func `private key files anywhere in home are denied`(path: String) throws {
        let fixture = try FixtureBuilder(name: "PrivateKeys")
        let url = try fixture.file(path, size: 64)
        #expect(try Self.policy(fixture).check(url) == .denied("Private key"), "\(path)")
    }

    @Test func `ollama key is denied while its models stay allowed`() throws {
        let fixture = try FixtureBuilder(name: "PrivateKeysOllama")
        let key = try fixture.file(".ollama/id_ed25519", size: 64)
        let models = try fixture.folder(".ollama/models")
        try fixture.file(".ollama/models/blobs/sha256-abc", size: 1024)
        let policy = try Self.policy(fixture)

        #expect(policy.check(key) == .denied("Private key"))
        #expect(policy.check(models) == .allowed)
        #expect(try policy.check(fixture.url("Library/Application Support/Tool/keynote-export.txt")) == .allowed)
        #expect(try policy.check(fixture.url("Library/Caches/com.example.keys")) == .allowed)
    }
}
