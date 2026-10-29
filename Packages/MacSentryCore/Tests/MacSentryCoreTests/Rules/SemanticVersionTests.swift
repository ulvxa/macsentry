import Foundation
import MacSentryCore
import MacSentryTestSupport
import Testing

struct SemanticVersionTests {
    @Test func `parses numeric components from names`() {
        #expect(SemanticVersion("2024.1.2")?.components == [2024, 1, 2])
        #expect(SemanticVersion("AndroidStudio2023.3")?.components == [2023, 3])
        #expect(SemanticVersion("1.2.3-beta")?.components == [1, 2, 3])
        #expect(SemanticVersion("4.1.")?.components == [4, 1])
        #expect(SemanticVersion("config") == nil)
        #expect(SemanticVersion("") == nil)
    }

    @Test func `compares numerically not lexically`() throws {
        let v19 = try #require(SemanticVersion("1.9"))
        let v110 = try #require(SemanticVersion("1.10"))
        #expect(v19 < v110)
        #expect(SemanticVersion("1.0") == SemanticVersion("1"))
        #expect(SemanticVersion("1.0.0")?.hashValue == SemanticVersion("1")?.hashValue)
        #expect(try #require(SemanticVersion("2.0")) > #require(SemanticVersion("1.99.99")))
    }

    @Test func `installed precision never marks the current version`() throws {
        let installed = try #require(SemanticVersion("4.1.1"))
        #expect(try #require(SemanticVersion("4.1")).isOlder(thanInstalled: installed) == false)
        #expect(try #require(SemanticVersion("4.1.1")).isOlder(thanInstalled: installed) == false)
        #expect(try #require(SemanticVersion("4.0")).isOlder(thanInstalled: installed))
        #expect(try #require(SemanticVersion("4.1.0")).isOlder(thanInstalled: installed))
        #expect(try #require(SemanticVersion("5")).isOlder(thanInstalled: installed) == false)
    }
}

struct OllamaModelReaderTests {
    @Test func `ollama manifests list each model with summed layer sizes`() throws {
        let fixture = try FixtureBuilder(name: "Ollama")
        let models = try fixture.folder(".ollama/models")
        let manifest = #"{"config":{"digest":"sha256:c","size":10},"layers":"#
            + #"[{"digest":"sha256:a","size":1000},{"digest":"sha256:b","size":200},{"digest":"sha256:a","size":1000}]}"#
        let library = try fixture.folder(".ollama/models/manifests/registry.ollama.ai/library/llama3")
        try Data(manifest.utf8).write(to: library.appending(path: "8b"))
        let user = try fixture.folder(".ollama/models/manifests/registry.ollama.ai/someone/tiny")
        try Data(#"{"layers":[{"digest":"sha256:z","size":5}]}"#.utf8).write(to: user.appending(path: "latest"))
        try Data("not json".utf8).write(to: user.appending(path: "broken"))

        let found = OllamaModelReader.models(in: models)
        #expect(found.map(\.reference) == ["llama3:8b", "someone/tiny:latest"])
        #expect(found.map(\.size) == [1210, 5])
        #expect(found.first?.cliCommand == "ollama rm llama3:8b")
    }
}
