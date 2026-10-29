import Foundation
import Testing
@testable import MacSentryCore

struct CLIToolInventoryTests {
    private func tools(_ home: OrphanFixture, bins: [String] = [], packages: [String] = [], sdk: [String] = []) throws -> CLIToolInventory {
        for name in bins {
            try home.fixture.file("bin/\(name)")
        }
        for name in packages {
            try home.fixture.folder("pkgs/\(name)")
        }
        for name in sdk {
            try home.fixture.folder("sdk/\(name)")
        }
        return try CLIToolInventory.scan(CLIToolInventory.Roots(
            binDirs: [home.fixture.url("bin")],
            packageDirs: [home.fixture.url("pkgs")],
            sdkDirs: sdk.isEmpty ? [:] : ["android": home.fixture.url("sdk")],
        ))
    }

    @Test func `scan reads bin dirs, packages, scopes, versions and sdk folders`() throws {
        let home = try OrphanFixture()
        let inventory = try tools(home, bins: ["swiftformat", "x"], packages: ["qt", "icu4c@76", "@nestjs/core"], sdk: ["emulator"])

        #expect(inventory.contains("swiftformat"))
        #expect(inventory.contains("qt"))
        #expect(inventory.contains("icu4c"))
        #expect(inventory.contains("core"))
        #expect(inventory.contains("emulator"))
        #expect(inventory.contains("android"))
        #expect(inventory.contains("x") == false)
    }

    @Test func `missing roots give an empty inventory`() throws {
        let home = try OrphanFixture()
        let inventory = try CLIToolInventory.scan(CLIToolInventory.Roots(
            binDirs: [home.fixture.url("nope")],
            packageDirs: [home.fixture.url("nope2")],
            sdkDirs: ["android": home.fixture.url("nope3")],
        ))
        #expect(inventory == .empty)
    }

    @Test func `leftovers of installed command line tools are not orphans`() async throws {
        let home = try OrphanFixture()
        try home.plist("Preferences/com.charcoaldesign.swiftformat.plist", [:])
        try home.folder("Application Support/com.vercel.cli")
        try home.plist("Preferences/com.qtproject.plist", [:])
        try home.plist("Preferences/com.android.Emulator.plist", [:])
        try home.folder("Application Support/com.fake.deletedapp")
        let inventory = try tools(home, bins: ["swiftformat", "vercel"], packages: ["qt"], sdk: ["emulator"])

        let findings = try await home.detector(cliTools: inventory).findings(inventory: [], library: home.library)

        #expect(findings.names == ["com.fake.deletedapp"])
    }

    @Test func `without the inventory the same vendor names are reported`() async throws {
        let home = try OrphanFixture()
        try home.folder("Application Support/com.vercel.cli")

        let findings = try await home.detector().findings(inventory: [], library: home.library)

        #expect(findings.names == ["com.vercel.cli"])
    }

    @Test func `sdk and installer vendors are never high confidence`() async throws {
        let home = try OrphanFixture()
        try home.plist("Preferences/com.firebase.FIRInstallations.plist", [:])
        try home.plist("Preferences/com.install4j.installations.plist", [:])
        try home.plist("Preferences/com.qtproject.plist", [:])
        try home.folder("Application Support/io.sentry")
        try home.folder("Application Support/com.fake.deletedapp")

        let findings = try await home.detector().findings(inventory: [], library: home.library)

        #expect(findings.count == 5)
        for name in ["com.firebase.FIRInstallations.plist", "com.install4j.installations.plist", "com.qtproject.plist", "io.sentry"] {
            #expect(findings.finding(named: name)?.candidate.confidence == .low)
        }
        #expect(findings.finding(named: "com.fake.deletedapp")?.candidate.confidence == .high)
    }

    @Test func `plain vendor names are low confidence`() async throws {
        let home = try OrphanFixture()
        try home.folder("Application Support/firebase")
        try home.folder("Application Support/qtproject")
        try home.folder("Caches/vercel")

        let findings = try await home.detector().findings(inventory: [], library: home.library)

        #expect(findings.count == 3)
        #expect(findings.allSatisfy { $0.candidate.confidence == .low })
    }
}
