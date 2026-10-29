import Foundation
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct ProtectionProviderTests {
    private struct Setup {
        let fixture: FixtureBuilder
        let target: URL
        let provider: ProtectionPolicyProvider
    }

    private func setup(_ store: any NeverTouchStore) throws -> Setup {
        let fixture = try FixtureBuilder(name: "ProviderReady")
        let target = try fixture.folder("Work/ClientWork/cache")
        let provider = try ProtectionPolicyProvider(
            homeURL: fixture.root,
            databaseURL: fixture.url("db/macsentry.sqlite"),
            neverTouchStore: store,
            ignoredPathStore: InMemoryIgnoredPathStore(),
        )
        return Setup(fixture: fixture, target: target, provider: provider)
    }

    @Test func `provider denies everything until the first refresh succeeds`() async throws {
        let setup = try setup(InMemoryNeverTouchStore())
        let cache = try setup.fixture.folder("Library/Caches/x")
        #expect(!setup.provider.isReady)
        #expect(setup.provider.check(cache) == .denied(ProtectionPolicyProvider.loadingReason))

        try await setup.provider.refresh()

        #expect(setup.provider.isReady)
        #expect(setup.provider.check(cache) == .allowed)
    }

    @Test func `failed first refresh keeps denying and surfaces the error`() async throws {
        let store = ScriptedNeverTouchStore(script: [.fail, .patterns(["**/ClientWork/**"]), .fail])
        let setup = try setup(store)
        let other = try setup.fixture.folder("Library/Caches/other")

        await #expect(throws: ProtectionStoreError.self) { try await setup.provider.refresh() }
        #expect(!setup.provider.isReady)
        #expect(setup.provider.check(other).isDenied)
        #expect(setup.provider.lastRefreshError != nil)

        try await setup.provider.refresh()
        #expect(setup.provider.lastRefreshError == nil)
        #expect(setup.provider.check(other) == .allowed)

        await #expect(throws: ProtectionStoreError.self) { try await setup.provider.refresh() }
        #expect(setup.provider.isReady)
        #expect(setup.provider.lastRefreshError != nil)
        #expect(setup.provider.check(setup.target).isDenied)
        #expect(setup.provider.check(other) == .allowed)
    }

    @Test func `older refresh still applies when the newer one fails`() async throws {
        let store = ScriptedNeverTouchStore(script: [.gated(["**/ClientWork/**"]), .fail])
        let setup = try setup(store)
        let slow = Task { try await setup.provider.refresh() }
        await store.waitUntilGated()

        await #expect(throws: ProtectionStoreError.self) { try await setup.provider.refresh() }
        await store.release()
        try await slow.value

        #expect(setup.provider.isReady)
        #expect(setup.provider.check(setup.target) == .denied("Matches Never Touch pattern **/ClientWork/**"))
        #expect(setup.provider.lastRefreshError != nil)
    }

    @Test func `older refresh finishing last never replaces a newer snapshot`() async throws {
        let store = ScriptedNeverTouchStore(script: [.gated(["**/ClientWork/**"]), .patterns([])])
        let setup = try setup(store)
        let slow = Task { try await setup.provider.refresh() }
        await store.waitUntilGated()

        try await setup.provider.refresh()
        await store.release()
        try await slow.value

        #expect(setup.provider.check(setup.target) == .allowed)
    }

    @Test func `unparsable stored pattern protects everything`() async throws {
        let setup = try setup(InMemoryNeverTouchStore(patterns: ["~/Work", "~/a[b]"]))
        let cache = try setup.fixture.folder("Library/Caches/x")

        try await setup.provider.refresh()

        let verdict = setup.provider.check(cache)
        #expect(verdict.isDenied)
        if case let .denied(reason) = verdict {
            #expect(reason.contains("~/a[b]"))
        }
    }
}

private actor ScriptedNeverTouchStore: NeverTouchStore {
    enum Step {
        case patterns([String])
        case gated([String])
        case fail
    }

    private var script: [Step]
    private var gate: CheckedContinuation<Void, Never>?

    init(script: [Step]) {
        self.script = script
    }

    func patterns() async throws -> [NeverTouchPattern] {
        let step = script.isEmpty ? .patterns([]) : script.removeFirst()
        let raw: [String]
        switch step {
        case .fail:
            throw ProtectionStoreError.database("scripted failure")
        case let .patterns(values):
            raw = values
        case let .gated(values):
            await withCheckedContinuation { gate = $0 }
            raw = values
        }
        return raw.enumerated().map { NeverTouchPattern(id: Int64($0.offset + 1), pattern: $0.element, createdAt: Date()) }
    }

    func waitUntilGated() async {
        while gate == nil {
            await Task.yield()
        }
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    func add(_: String, note _: String?) {}

    func remove(id _: Int64) {}
}
