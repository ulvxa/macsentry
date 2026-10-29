import Foundation
import Testing
@testable import MacSentryCore

struct OrphanLocationTests {
    @Test func `container identity comes from container metadata`() async throws {
        let home = try OrphanFixture()
        let metadata = DefaultOrphanDetector.containerMetadataName
        try home.plist("Containers/1A2B3C4D-0000-4000-8000-000000000001/\(metadata)", ["MCMMetadataIdentifier": "com.fake.sandboxed"])
        try home.plist("Containers/1A2B3C4D-0000-4000-8000-000000000002/\(metadata)", ["MCMMetadataIdentifier": "com.spotify.client"])
        try home.plist("Containers/com.fake.deletedapp/\(metadata)", ["MCMMetadataIdentifier": "com.spotify.client.widget"])
        let spotify = try home.app("Player", bundleID: "com.spotify.client")

        let findings = try await home.detector().findings(inventory: [spotify], library: home.library)

        let finding = try #require(findings.first)
        #expect(findings.count == 1)
        #expect(finding.candidate.url.lastPathComponent == "1A2B3C4D-0000-4000-8000-000000000001")
        #expect(finding.explanation.identity == "com.fake.sandboxed")
        #expect(finding.candidate.appBundleID == "com.fake.sandboxed")
        #expect(finding.candidate.confidence == .high)
        #expect(finding.candidate.ruleID == "orphan.containers")
        #expect(finding.candidate.tier == .yellow)
    }

    @Test func `container with unreadable metadata is low confidence`() async throws {
        let home = try OrphanFixture()
        try home.folder("Containers/com.fake.nometadata")
        try home.rawFile("Containers/com.fake.garbage/\(DefaultOrphanDetector.containerMetadataName)", Data("not a plist".utf8))
        try home.folder("Containers/com.spotify.client")
        let spotify = try home.app("Player", bundleID: "com.spotify.client")

        let findings = try await home.detector().findings(inventory: [spotify], library: home.library)

        #expect(findings.names == ["com.fake.nometadata", "com.fake.garbage"])
        #expect(findings.allSatisfy { $0.candidate.confidence == .low })
        #expect(findings.allSatisfy { $0.candidate.reason.contains("container metadata could not be read") })
    }

    @Test func `orphan launch agent is red flag only with bootout command and program path`() async throws {
        let home = try OrphanFixture()
        let program = try home.fixture.url("Applications/Gone.app/Contents/MacOS/updater").path(percentEncoded: false)
        let plist = try home.plist("LaunchAgents/com.fake.updater.plist", [
            "Label": "com.fake.updater",
            "ProgramArguments": [program, "--daemon"],
        ])

        let findings = try await home.detector().findings(inventory: [], library: home.library)

        let finding = try #require(findings.first)
        let candidate = finding.candidate
        #expect(findings.count == 1)
        #expect(candidate.ruleID == "orphan.launchAgents")
        #expect(candidate.tier == .red)
        #expect(candidate.action == .flagOnly)
        #expect(candidate.kind == .file)
        #expect(candidate.cliCommand == "launchctl bootout gui/$(id -u) '\(plist.path(percentEncoded: false))'")
        #expect(candidate.reason.contains(program))
        #expect(candidate.reason.contains("no longer exists"))
        #expect(finding.explanation.identity == "com.fake.updater")
        #expect(candidate.confidence == .high)
    }

    @Test func `launch agent running a program inside an installed app is not an orphan`() async throws {
        let home = try OrphanFixture()
        let tool = try home.app("Tool", bundleID: "com.example.tool")
        let program = tool.url.appending(path: "Contents/Library/LaunchServices/agent").path(percentEncoded: false)
        try home.plist("LaunchAgents/net.unrelated.agent.plist", ["Label": "net.unrelated.agent", "Program": program])

        let findings = try await home.detector().findings(inventory: [tool], library: home.library)

        #expect(findings.isEmpty)
    }

    @Test func `unreadable launch agent falls back to file name with low confidence`() async throws {
        let home = try OrphanFixture()
        try home.rawFile("LaunchAgents/com.fake.broken.plist", Data("<plist".utf8))

        let findings = try await home.detector().findings(inventory: [], library: home.library)

        let finding = try #require(findings.first)
        #expect(finding.explanation.identity == "com.fake.broken")
        #expect(finding.candidate.confidence == .low)
        #expect(finding.candidate.cliCommand?.hasPrefix("launchctl bootout gui/$(id -u) ") == true)
    }

    @Test func `older version folders of installed products are medium orphans`() async throws {
        let home = try OrphanFixture()
        for path in [
            "Application Support/JetBrains/IntelliJIdea2022.3", "Application Support/JetBrains/IntelliJIdea2024.1",
            "Application Support/JetBrains/PyCharm2021.1", "Caches/JetBrains/IntelliJIdea2022.3",
            "Application Support/Blender/3.6", "Application Support/Blender/4.1", "Application Support/Blender/scripts",
            "Application Support/Google/AndroidStudio2023.1", "Application Support/Google/AndroidStudio2024.1",
            "Application Support/AndroidStudio2022.2", "Logs/Godot/3.5", "Logs/Godot/4.2",
        ] {
            try home.folder(path)
        }
        let apps = try [
            home.app("IntelliJ IDEA", bundleID: "com.jetbrains.intellij", version: "2024.1.2"),
            home.app("Blender", bundleID: "org.blenderfoundation.blender", version: "4.1.0"),
            home.app("Android Studio", bundleID: "com.google.android.studio", version: "2024.1"),
            home.app("Godot", bundleID: "org.godotengine.godot"),
        ]

        let findings = try await home.detector().findings(inventory: apps, library: home.library)

        let paths = Set(findings.map { $0.candidate.url.path(percentEncoded: false) })
        let expected = try Set([
            "Application Support/JetBrains/IntelliJIdea2022.3", "Caches/JetBrains/IntelliJIdea2022.3",
            "Application Support/Blender/3.6", "Application Support/Google/AndroidStudio2023.1",
            "Application Support/AndroidStudio2022.2", "Logs/Godot/3.5",
        ].map { try OrphanFixture.pathKey(home.fixture.url("home/Library/\($0)")) })
        #expect(paths == expected)
        for finding in findings {
            #expect(finding.candidate.confidence == .medium)
            #expect(finding.candidate.ruleID == "orphan.oldVersion")
            #expect(finding.candidate.reason.hasPrefix("Settings from an older version"))
            #expect(finding.candidate.category == .orphan)
        }
        let blender = try #require(findings.finding(named: "3.6"))
        #expect(blender.candidate.appBundleID == "org.blenderfoundation.blender")
        #expect(blender.explanation.kind == .olderVersion(product: "Blender", folderVersion: "3.6", currentVersion: "4.1.0"))
        #expect(blender.candidate.tier == .yellow)
        #expect(findings.first { $0.location == .caches }?.candidate.tier == .green)
    }

    @Test func `preferences plists are one candidate each under one rule`() async throws {
        let home = try OrphanFixture()
        try home.plist("Preferences/com.fake.deletedapp.plist", ["key": "value"])
        try home.plist("Preferences/com.fake.deletedapp.LSSharedFileList.plist", ["key": "value"])
        try home.plist("Preferences/com.spotify.client.plist", ["key": "value"])
        try home.folder("Preferences/ByHost")
        try home.file("Preferences/notes.txt", size: 4)
        let spotify = try home.app("Player", bundleID: "com.spotify.client")

        let findings = try await home.detector().findings(inventory: [spotify], library: home.library)

        #expect(findings.names == ["com.fake.deletedapp.plist", "com.fake.deletedapp.LSSharedFileList.plist"])
        for finding in findings {
            #expect(finding.candidate.ruleID == "orphan.preferences")
            #expect(finding.candidate.kind == .file)
            #expect(finding.candidate.tier == .green)
            #expect(finding.candidate.logicalSize > 0)
            #expect(finding.explanation.identity.hasPrefix("com.fake.deletedapp"))
        }
    }

    @Test func `each location uses its identity source rule id and tier`() async throws {
        let home = try OrphanFixture()
        try home.folder("Saved Application State/com.fake.gone.savedState")
        try home.folder("Saved Application State/com.spotify.client.savedState")
        try home.folder("Group Containers/ABCDE12345.com.fake.shared")
        try home.folder("Group Containers/ABCDE12345.com.spotify.client")
        try home.file("HTTPStorages/com.fake.gone.binarycookies", size: 64)
        try home.file("HTTPStorages/com.spotify.client.binarycookies", size: 64)
        try home.folder("WebKit/com.fake.gone")
        try home.folder("Logs/com.fake.gone2")
        let spotify = try home.app("Player", bundleID: "com.spotify.client")

        let findings = try await home.detector().findings(inventory: [spotify], library: home.library)

        let byName = Dictionary(uniqueKeysWithValues: findings.map { ($0.candidate.url.lastPathComponent, $0) })
        #expect(byName.count == 5)
        #expect(byName["com.fake.gone.savedState"]?.candidate.ruleID == "orphan.savedApplicationState")
        #expect(byName["com.fake.gone.savedState"]?.explanation.identity == "com.fake.gone")
        #expect(byName["ABCDE12345.com.fake.shared"]?.candidate.ruleID == "orphan.groupContainers")
        #expect(byName["ABCDE12345.com.fake.shared"]?.explanation.identity == "com.fake.shared")
        #expect(byName["ABCDE12345.com.fake.shared"]?.candidate.tier == .yellow)
        #expect(byName["com.fake.gone.binarycookies"]?.candidate.ruleID == "orphan.httpStorages")
        #expect(byName["com.fake.gone.binarycookies"]?.explanation.identity == "com.fake.gone")
        #expect(byName["com.fake.gone"]?.candidate.ruleID == "orphan.webKit")
        #expect(byName["com.fake.gone2"]?.candidate.ruleID == "orphan.logs")
        #expect(findings.allSatisfy { $0.location == .groupContainers || $0.candidate.tier == .green })
    }

    @Test func `group container identity strips team id and group prefixes`() {
        #expect(DefaultOrphanDetector.groupContainerIdentity("UBF8T346G9.Office") == "Office")
        #expect(DefaultOrphanDetector.groupContainerIdentity("243LU875E5.groups.com.apple.podcasts") == "com.apple.podcasts")
        #expect(DefaultOrphanDetector.groupContainerIdentity("group.com.docker") == "com.docker")
        #expect(DefaultOrphanDetector.groupContainerIdentity("systemgroup.com.apple.mobileactivationd") == "com.apple.mobileactivationd")
        #expect(DefaultOrphanDetector.groupContainerIdentity("com.fake.plain") == "com.fake.plain")
    }
}
