import Foundation
import MacSentryCore
import MacSentryTestSupport
import Testing

struct AppInventoryTests {
    @Test func `reads apps from every root with names and versions`() async throws {
        let fixture = try FixtureBuilder(name: "Inventory")
        try fixture.bundle("Applications/Foo.app", id: "com.example.foo", name: "Foo", version: "1.2.3")
        try fixture.bundle("Applications/Utilities/Bar.app", id: "com.example.bar", name: nil, version: nil)
        try fixture.bundle("home/Applications/Baz.app", id: "com.example.baz", name: "Baz Pro", version: "9")
        try fixture.bundle("Applications/Suite/Suite Tool.app", id: "com.example.suite", name: "Suite Tool", version: "2024")
        try fixture.bundle(
            "Applications/Unity/Hub/Editor/2022.3.1f1/Unity.app",
            id: "com.unity3d.UnityEditor5.x",
            name: "Unity",
            version: "2022.3.1f1",
        )
        try fixture.folder("Applications/Broken.app/Contents")
        try fixture.bundle("Elsewhere/Linked.app", id: "com.example.linked", name: "Linked", version: "1")
        try fixture.symlink("Applications/Linked.app", to: fixture.url("Elsewhere/Linked.app"))

        let inventory = try SystemAppInventory(
            appRoots: [fixture.url("Applications"), fixture.url("Applications/Utilities"), fixture.url("home/Applications")],
            editorRoots: [fixture.url("Applications/Unity/Hub/Editor")],
            runningBundleIDs: { [] },
        )
        let apps = await inventory.installedApps()
        let byID = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleID, $0) })

        #expect(apps.count == 5)
        #expect(Set(byID.keys) == [
            "com.example.foo",
            "com.example.bar",
            "com.example.baz",
            "com.example.suite",
            "com.unity3d.UnityEditor5.x",
        ])
        #expect(byID["com.example.foo"]?.version == "1.2.3")
        #expect(byID["com.example.foo"]?.url.lastPathComponent == "Foo.app")
        #expect(byID["com.example.bar"]?.name == "Bar")
        #expect(byID["com.example.bar"]?.version == nil)
        #expect(byID["com.example.baz"]?.name == "Baz Pro")
        #expect(byID["com.unity3d.UnityEditor5.x"]?.version == "2022.3.1f1")
    }

    @Test func `missing roots yield no apps`() async {
        let inventory = SystemAppInventory(appRoots: [URL(filePath: "/nonexistent-macsentry-root")], runningBundleIDs: { [] })
        #expect(await inventory.installedApps().isEmpty)
    }

    @Test func `standard roots resolve user applications against injected home and include Apple apps`() {
        let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)
        let inventory = SystemAppInventory.standard(homeURL: home)
        #expect(inventory.appRoots.map { $0.path(percentEncoded: false) } == [
            "/Applications/",
            "/Applications/Utilities/",
            "/Users/tester/Applications/",
            "/System/Applications/",
            "/System/Applications/Utilities/",
            "/System/Library/CoreServices/",
        ])
        #expect(inventory.editorRoots.map { $0.path(percentEncoded: false) } == ["/Applications/Unity/Hub/Editor/"])
    }

    @Test func `helper bundle ids come from login items helpers and frameworks`() async throws {
        let fixture = try FixtureBuilder(name: "Inventory")
        let app = "Applications/Chat.app"
        try fixture.bundle(app, id: "com.example.chat", name: "Chat", version: "1")
        try fixture.bundle("\(app)/Contents/Library/LoginItems/Chat Launcher.app", id: "com.example.chat.launcher", name: "L", version: nil)
        try fixture.bundle("\(app)/Contents/Helpers/Chat Agent.app", id: "com.example.chat.agent", name: "A", version: nil)
        try fixture.bundle("\(app)/Contents/Frameworks/Chat Helper.app", id: "com.example.chat.helper", name: "H", version: nil)
        try fixture.bundle("\(app)/Contents/Frameworks/Chat Helper (GPU).app", id: "com.example.chat.helper", name: "H", version: nil)
        try fixture.folder("\(app)/Contents/Frameworks/Electron Framework.framework")

        let inventory = try SystemAppInventory(appRoots: [fixture.url("Applications")], runningBundleIDs: { [] })
        let chat = try #require(await inventory.installedApps().first)
        #expect(Set(inventory.helperBundleIDs(of: chat)) == [
            "com.example.chat.launcher",
            "com.example.chat.agent",
            "com.example.chat.helper",
        ])
        #expect(inventory.helperBundleIDs(of: chat).count == 3)
    }

    @Test func `running state comes from the injected provider`() {
        let inventory = SystemAppInventory(appRoots: [], runningBundleIDs: { ["com.apple.dt.Xcode"] })
        #expect(inventory.isRunning(bundleID: "com.apple.dt.Xcode"))
        #expect(!inventory.isRunning(bundleID: "com.docker.docker"))
    }

    @Test func `double returns configured values`() async {
        let app = InstalledApp(bundleID: "com.example.x", name: "X", version: "1", url: URL(filePath: "/Applications/X.app"))
        let double = TestAppInventory(apps: [app], running: ["com.example.x"], helpers: ["com.example.x": ["com.example.x.helper"]])
        #expect(await double.installedApps() == [app])
        #expect(double.isRunning(bundleID: "com.example.x"))
        #expect(double.helperBundleIDs(of: app) == ["com.example.x.helper"])
    }
}

private extension FixtureBuilder {
    func bundle(_ relativePath: String, id: String, name: String?, version: String?) throws {
        let contents = try folder("\(relativePath)/Contents")
        var plist: [String: String] = ["CFBundleIdentifier": id]
        plist["CFBundleName"] = name
        plist["CFBundleShortVersionString"] = version
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
    }
}
