import Foundation
import MacSentryCore
import Testing

struct SystemAllowlistTests {
    @Test func `bundled allowlist contains the documented entries`() throws {
        let allowlist = try SystemAllowlist.bundled()
        let names = Set(allowlist.entries.map(\.name))
        let documented: Set = [
            "CloudDocs", "CallHistoryDB", "AddressBook", "Knowledge", "CrashReporter", "SyncServices", "icdd", "FileProvider",
            "iCloud", "Dock", "com.crashlytics", "Google", "Microsoft", "Adobe", "JetBrains", "Code", "Python", "Homebrew",
        ]
        #expect(documented.isSubset(of: names))
        #expect(allowlist.entries.first { $0.name == "Google" }?.whenInstalledBundleIDPrefix == "com.google.")
        #expect(allowlist.entries.first { $0.name == "Adobe" }?.whenInstalledBundleIDPrefix == "com.adobe.")
    }

    @Test func `conditional entries are active only with a matching installed app`() throws {
        let allowlist = try SystemAllowlist.bundled()

        let none = allowlist.activeNames(installedBundleIDs: [])
        let google = allowlist.activeNames(installedBundleIDs: ["com.google.Chrome"])

        #expect(!none.contains("google"))
        #expect(!none.contains("adobe"))
        #expect(none.contains("clouddocs"))
        #expect(google.contains("google"))
        #expect(!google.contains("adobe"))
    }

    @Test(arguments: [
        #"{"version": 1, "entries": [{"name": "A", "extra": true}]}"#,
        #"{"version": 1, "entries": [], "comment": "x"}"#,
        #"{"version": 2, "entries": []}"#,
        #"{"version": 1, "entries": [{"name": "A"}, {"name": "a"}]}"#,
        #"{"version": 1, "entries": [{"name": " A"}]}"#,
        #"{"version": 1, "entries": [{"name": ""}]}"#,
        #"{"version": 1, "entries": [{"name": "A", "whenInstalledBundleIDPrefix": ""}]}"#,
        #"{"entries": []}"#,
        "not json",
    ])
    func `invalid allowlists are rejected`(json: String) {
        #expect(throws: OrphanDetectorError.self) {
            try SystemAllowlist(data: Data(json.utf8))
        }
    }

    @Test func `valid allowlist decodes`() throws {
        let json = #"{"version": 1, "entries": [{"name": "A"}, {"name": "B", "whenInstalledBundleIDPrefix": "com.b."}]}"#
        let allowlist = try SystemAllowlist(data: Data(json.utf8))
        #expect(allowlist == SystemAllowlist(entries: [.init(name: "A"), .init(name: "B", whenInstalledBundleIDPrefix: "com.b.")]))
    }
}
