import Foundation
import Testing
@testable import MacSentryCore

struct OrphanDetectorTests {
    @Test func `deleted app folder in Application Support is a high confidence orphan`() async throws {
        let home = try OrphanFixture()
        let folder = try home.folder("Application Support/com.fake.deletedapp")
        try home.file("Application Support/com.fake.deletedapp/data.db", size: 10)
        let editor = try home.app("Editor", bundleID: "com.example.editor")

        let findings = try await home.detector().findings(inventory: [editor], library: home.library)

        #expect(findings.count == 1)
        let finding = try #require(findings.first)
        let candidate = finding.candidate
        #expect(OrphanFixture.pathKey(candidate.url) == OrphanFixture.pathKey(folder))
        #expect(candidate.category == .orphan)
        #expect(candidate.confidence == .high)
        #expect(candidate.ruleID == "orphan.applicationSupport")
        #expect(candidate.tier == .yellow)
        #expect(candidate.action == .quarantine)
        #expect(candidate.kind == .folder)
        #expect(candidate.sessionID == 7)
        #expect(candidate.status == .found)
        #expect(candidate.appBundleID == "com.fake.deletedapp")
        #expect(candidate.cliCommand == nil)
        #expect(candidate.logicalSize == OrphanFixture.folderSize.logical)
        #expect(candidate.freeableSize == OrphanFixture.folderSize.freeable)
        #expect(candidate.reason.contains("com.fake.deletedapp"))
        #expect(candidate.reason.contains("LaunchServices knows no app for it"))
        #expect(finding.location == .applicationSupport)
        #expect(finding.explanation.kind == .noInstalledApp)
        #expect(finding.explanation.failedChecks == OrphanCheck.allCases)
        #expect(finding.explanation.guessedAppName == "deletedapp")
    }

    @Test func `detect returns the candidates of the findings`() async throws {
        let home = try OrphanFixture()
        try home.folder("Application Support/com.fake.deletedapp")
        let detector = try home.detector()

        let candidates = try await detector.detect(inventory: [], library: home.library)
        let findings = try await detector.findings(inventory: [], library: home.library)

        #expect(candidates == findings.map(\.candidate))
        #expect(candidates.count == 1)
    }

    @Test func `folder named after installed bundle id is not an orphan`() async throws {
        let home = try OrphanFixture()
        try home.folder("Application Support/com.spotify.client")
        try home.folder("Caches/com.spotify.client")
        try home.folder("WebKit/COM.SPOTIFY.CLIENT")
        let spotify = try home.app("Spotify", bundleID: "com.spotify.client")

        let findings = try await home.detector().findings(inventory: [spotify], library: home.library)

        #expect(findings.isEmpty)
    }

    @Test func `folder with installed bundle id as prefix is not an orphan`() async throws {
        let home = try OrphanFixture()
        try home.folder("Caches/com.spotify.client.helper")
        try home.folder("HTTPStorages/com.spotify.client.helper.renderer")
        let spotify = try home.app("Player", bundleID: "com.spotify.client")

        let findings = try await home.detector().findings(inventory: [spotify], library: home.library)

        #expect(findings.isEmpty)
    }

    @Test func `folders of helper bundles are not orphans`() async throws {
        let home = try OrphanFixture()
        try home.folder("Application Support/com.vendorx.launcher")
        try home.folder("Caches/com.vendorx.xpc.worker")
        try home.folder("Caches/com.injected.agent.cache")
        try home.folder("Caches/com.vendorx.other")
        let app = try home.app(
            "Zed Main",
            bundleID: "com.vendorx.main",
            helpers: ["Library/LoginItems": "com.vendorx.launcher", "XPCServices": "com.vendorx.xpc.worker"],
        )

        let findings = try await home.detector(helperBundleIDs: ["com.injected.agent"])
            .findings(inventory: [app], library: home.library)

        #expect(findings.names == ["com.vendorx.other"])
        #expect(findings.first?.candidate.confidence == .medium)
    }

    @Test func `folder matching normalized app name is not an orphan`() async throws {
        let home = try OrphanFixture()
        try home.folder("Application Support/Sketch-Up Pro")
        try home.folder("Logs/sketchup_pro")
        try home.folder("Caches/SketchUpPro Data")
        try home.folder("Application Support/Arc")
        let sketch = try home.app("SketchUp Pro", bundleID: "com.example.sketch")
        let arc = try home.app("Arc", bundleID: "company.thebrowser.Browser")

        let findings = try await home.detector().findings(inventory: [sketch, arc], library: home.library)

        #expect(findings.isEmpty)
    }

    @Test func `short app names only match exactly`() async throws {
        let home = try OrphanFixture()
        try home.folder("Application Support/Search Tool")
        let arc = try home.app("Arc", bundleID: "company.thebrowser.Browser")

        let findings = try await home.detector().findings(inventory: [arc], library: home.library)

        #expect(findings.names == ["Search Tool"])
    }

    @Test func `apple and allowlisted system folders are never orphans`() async throws {
        let home = try OrphanFixture()
        for location in ["Application Support", "Caches", "HTTPStorages", "WebKit", "Logs"] {
            try home.folder("\(location)/com.apple.Safari")
        }
        for name in [
            "CloudDocs",
            "CallHistoryDB",
            "AddressBook",
            "Knowledge",
            "CrashReporter",
            "SyncServices",
            "icdd",
            "FileProvider",
            "iCloud",
            "Dock",
            "Microsoft",
            "JetBrains",
            "Code",
            "Python",
            "Homebrew",
        ] {
            try home.folder("Application Support/\(name)")
        }
        try home.folder("Caches/com.crashlytics")
        try home.folder("Caches/com.crashlytics.data")
        try home.folder("Logs/DiagnosticReports")
        try home.folder("Group Containers/group.com.apple.notes")
        try home.folder("Group Containers/243LU875E5.groups.com.apple.podcasts")
        try home.folder("Group Containers/UBF8T346G9.Office")
        try home.plist("Containers/4C0F6A55-D0B2-4D0B-9D8A-0E5F6D2B7A11/.com.apple.containermanagerd.metadata.plist", [
            "MCMMetadataIdentifier": "com.apple.Notes",
        ])
        try home.folder("Containers/com.apple.mail")
        try home.folder("Saved Application State/com.apple.Terminal.savedState")
        try home.plist("Preferences/com.apple.dock.plist", ["orientation": "left"])
        try home.plist("Preferences/loginwindow.plist", [:])
        try home.plist("LaunchAgents/homebrew.mxcl.redis.plist", ["Label": "homebrew.mxcl.redis"])
        try home.plist("LaunchAgents/com.apple.example.plist", ["Label": "com.apple.example"])

        let findings = try await home.detector().findings(inventory: [], library: home.library)

        #expect(findings.isEmpty)
    }

    @Test func `vendor folders Google and Adobe are allowlisted only when a vendor app is installed`() async throws {
        let home = try OrphanFixture()
        try home.folder("Application Support/Google")
        try home.folder("Application Support/Adobe")
        let chrome = try home.app("Chrome", bundleID: "com.google.Chrome")
        let photoshop = try home.app("Photoshop", bundleID: "com.adobe.Photoshop")
        let detector = try home.detector()

        let without = try await detector.findings(inventory: [], library: home.library)
        let with = try await detector.findings(inventory: [chrome, photoshop], library: home.library)

        #expect(without.names == ["Google", "Adobe"])
        #expect(without.allSatisfy { $0.candidate.confidence == .low })
        #expect(with.isEmpty)
    }

    @Test func `reverse DNS sharing a vendor with an installed app is medium confidence`() async throws {
        let home = try OrphanFixture()
        try home.folder("Application Support/com.microsoft.teams")
        let word = try home.app("Microsoft Word", bundleID: "com.microsoft.Word")

        let findings = try await home.detector().findings(inventory: [word], library: home.library)

        let finding = try #require(findings.finding(named: "com.microsoft.teams"))
        #expect(findings.count == 1)
        #expect(finding.candidate.confidence == .medium)
        #expect(finding.explanation.notes.contains { $0.contains("com.microsoft") })
    }

    @Test func `name that is a vendor prefix of an installed id is not an orphan`() async throws {
        let home = try OrphanFixture()
        try home.folder("Caches/com.docker")
        try home.folder("Group Containers/group.com.docker")
        let docker = try home.app("Docker Desktop", bundleID: "com.docker.docker")

        let findings = try await home.detector().findings(inventory: [docker], library: home.library)

        #expect(findings.isEmpty)
    }

    @Test func `plain name with no match is low confidence`() async throws {
        let home = try OrphanFixture()
        try home.folder("Application Support/ollama-models")
        let editor = try home.app("Editor", bundleID: "com.example.editor")

        let findings = try await home.detector().findings(inventory: [editor], library: home.library)

        let finding = try #require(findings.first)
        #expect(findings.count == 1)
        #expect(finding.candidate.confidence == .low)
        #expect(finding.candidate.appBundleID == nil)
        #expect(finding.explanation.failedChecks == [.installedBundleID, .installedAppName, .systemFolder, .claimedByRule])
        #expect(finding.candidate.reason.contains("command line tool"))
    }

    @Test func `claimed protected and LaunchServices known folders are skipped`() async throws {
        let home = try OrphanFixture()
        let claimed = try home.folder("Caches/com.fake.claimed")
        try home.folder("Caches/com.fake.protected")
        try home.folder("Caches/com.fake.registered")
        try home.folder("Caches/com.fake.reported")

        let findings = try await home.detector(
            policy: DenyNamesPolicy(names: ["com.fake.protected"]),
            knownToLaunchServices: ["com.fake.registered"],
            claimed: [claimed],
        ).findings(inventory: [], library: home.library)

        #expect(findings.names == ["com.fake.reported"])
        #expect(findings.first?.candidate.tier == .green)
        #expect(findings.first?.candidate.ruleID == "orphan.caches")
    }

    @Test func `missing library folders produce no findings`() async throws {
        let home = try OrphanFixture()

        let findings = try await home.detector().findings(inventory: [], library: home.library)

        #expect(findings.isEmpty)
    }

    @Test func `stub detector returns configured findings or error`() async throws {
        let home = try OrphanFixture()
        try home.folder("Application Support/com.fake.deletedapp")
        let real = try await home.detector().findings(inventory: [], library: home.library)

        let stub = StubOrphanDetector(findings: real)
        #expect(try await stub.detect(inventory: [], library: home.library) == real.map(\.candidate))
        await #expect(throws: OrphanDetectorError.allowlistMissing) {
            try await StubOrphanDetector(error: .allowlistMissing).findings(inventory: [], library: home.library)
        }
    }
}
