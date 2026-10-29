import Foundation
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct ProtectionPolicyTests {
    private static let systemPaths = [
        "/", "/System", "/System/Library/CoreServices", "/bin/ls", "/sbin/mount", "/usr", "/usr/bin/swift",
        "/usr/lib/libSystem.dylib", "/usr/local", "/private/var/db", "/var/log/system.log", "/private/etc/hosts",
        "/etc/hosts", "/Library/Apple/System", "/Library/Keychains/System.keychain", "/Library", "/private",
        "/Applications", "/Applications/Safari.app", "/Applications/Safari.app/Contents/MacOS/Safari",
        "/Applications/Utilities", "/Applications/Utilities/Terminal.app/Contents", "/Users", "/Users/someone",
        "/Users/Shared", "/Volumes", "/Volumes/Backup",
    ]

    private static let homePaths = [
        "Applications/Tool.app", "Applications/Tool.app/Contents/Info.plist",
        "Library/Keychains", "Library/Keychains/login.keychain-db", "Library/Mail/V10/MailData",
        "Library/Messages/chat.db", "Library/Mobile Documents/com~apple~CloudDocs/a.txt", "Library/CloudStorage/Dropbox",
        "Library/Accounts/Accounts4.sqlite", "Library/Cookies/Cookies.binarycookies", "Library/LaunchAgents/com.x.plist",
        "Library/Preferences/com.example.installed.plist", "Library/Preferences",
        ".ssh", ".ssh/id_ed25519", ".gnupg/pubring.kbx", ".aws/credentials", ".config/gcloud/credentials.db",
        ".kube/config", ".docker/config.json", ".docker", ".zshrc",
        "Library/Application Support/Ledger Live", "Library/Application Support/Ledger Live/app.json",
        "Library/Application Support/Exodus Wallet/data", "Library/Application Support/com.bitwallet.app",
        "Library/Application Support", "Library/Containers/com.x/Data/Library/Application Support/MyWallet",
        "Music/Music", "Music/Music/Media.localized/song.m4a", "Pictures/Photos Library.photoslibrary",
        "Pictures/Old/Trip.photoslibrary/database", "Pictures/Archive.photolibrary",
        "MacSentry Quarantine", "MacSentry Quarantine/2026-10-29_064512/Users/x/Library/Caches/foo",
        "Library/Application Support/MacSentry", "Library/Application Support/MacSentry/macsentry.sqlite",
        ".Trash/x", ".Trash/old/movie.mov", "Library/Safari", "Library/Safari/History.db", "Library/Calendars",
        "Library/Calendars/Calendar Cache", "Library/Application Support/MobileSync/Backup",
        "Library/Application Support/MobileSync/Backup/00008110-001A",
        "Documents", "Desktop", "Downloads", "Movies", "Library", "Code",
        "Code/app/.git", "Code/app/.git/objects", "Code/app", "Code/app/src", "Code/app/src/main.swift",
        "Code/app/node_modules/pkg/.git", "Code/app/packages/web/README.md",
    ]

    private static let allowedHomePaths = [
        "Library/Caches/com.example.app", "Library/Caches/com.example.app/data.bin",
        "Library/Developer/Xcode/DerivedData", "Library/Application Support/Slack/Cache",
        "Library/Preferences/com.example.uninstalled.plist", "Library/Containers/com.apple.mail/Data/Library/Mail Downloads",
        ".npm/_cacache", ".gradle/caches", "big.iso",
        "Code/app/node_modules", "Code/app/node_modules/other/index.js", "Code/app/packages/web/.next",
        "Code/app/target/debug", "Code/loose/notes.txt",
    ]

    private struct Home {
        let fixture: FixtureBuilder
        let policy: DefaultProtectionPolicy

        init(neverTouch: [String] = [], ignored: [String] = [], isKnownArtifact: ArtifactPredicate? = nil) throws {
            let fixture = try FixtureBuilder(name: "Protection")
            self.fixture = fixture
            for folder in [
                "Documents",
                "Desktop",
                "Downloads",
                "Movies",
                "Library/Caches/com.example.app",
                "Code/app/src",
                "Code/app/node_modules/pkg",
                "Code/app/packages/web",
                "Code/loose",
            ] {
                try fixture.folder(folder)
            }
            try fixture.file("Code/app/.git/HEAD", size: 23)
            try fixture.file("Code/app/node_modules/pkg/.git", size: 10)
            try fixture.file("big.iso", size: 1)
            policy = try DefaultProtectionPolicy(
                homeURL: fixture.root,
                databaseURL: fixture.url("Library/Application Support/MacSentry/macsentry.sqlite"),
                installedBundleIDs: ["com.example.installed"],
                neverTouchPatterns: neverTouch,
                ignoredPaths: ignored.map { try fixture.url($0) },
                isKnownArtifact: isKnownArtifact ?? DefaultProtectionPolicy.isDefaultArtifact,
            )
        }

        func check(_ relative: String) throws -> ProtectionVerdict {
            try policy.check(fixture.url(relative))
        }
    }

    @Test(arguments: systemPaths)
    func `built in system path is denied`(path: String) throws {
        let home = try Home()
        #expect(home.policy.check(URL(filePath: path)).isDenied, "\(path)")
    }

    @Test(arguments: homePaths)
    func `built in home path is denied`(path: String) throws {
        let home = try Home()
        #expect(try home.check(path).isDenied, "\(path)")
    }

    @Test(arguments: allowedHomePaths)
    func `ordinary home path is allowed`(path: String) throws {
        let home = try Home()
        #expect(try home.check(path) == .allowed, "\(path)")
    }

    @Test func `home itself and its ancestors are denied`() throws {
        let home = try Home()
        #expect(home.policy.check(home.fixture.root).isDenied)
        #expect(home.policy.check(home.fixture.root.deletingLastPathComponent()).isDenied)
    }

    @Test func `usr local contents are allowed`() throws {
        let home = try Home()
        #expect(home.policy.check(URL(filePath: "/usr/local/x")) == .allowed)
        #expect(home.policy.check(URL(filePath: "/usr/local/Cellar/old-formula")) == .allowed)
    }

    @Test func `quarantine folder itself is denied`() throws {
        let home = try Home()
        try home.fixture.folder("MacSentry Quarantine")
        #expect(try home.check("MacSentry Quarantine") == .denied("MacSentry quarantine folder"))
    }

    @Test func `user glob denies matching fixture path`() throws {
        let home = try Home(neverTouch: ["**/ClientWork/**"])
        try home.fixture.folder("Work/ClientWork/acme/node_modules")
        #expect(try home.check("Work/ClientWork").isDenied)
        #expect(try home.check("Work/ClientWork/acme/node_modules").isDenied)
        #expect(try home.check("Work/clientwork/acme").isDenied)
        #expect(try home.check("Work/OtherWork") == .allowed)
    }

    @Test func `user glob protects folders on the way to a match`() throws {
        let home = try Home(neverTouch: ["~/Work/*/secret"])
        #expect(try home.check("Work/acme") == .denied("Matches Never Touch pattern ~/Work/*/secret"))
        #expect(try home.check("Work/acme/secret/x").isDenied)
        #expect(try home.check("Work/acme/public") == .allowed)
    }

    @Test func `ignored path and its contents are denied`() throws {
        let home = try Home(ignored: ["Library/Caches/com.example.app"])
        #expect(try home.check("Library/Caches/com.example.app") == .denied("Ignored by you"))
        #expect(try home.check("Library/Caches/com.example.app/blob").isDenied)
        #expect(try home.check("Library/Caches/com.other") == .allowed)
    }

    @Test func `dot dot path resolving into protected dir is denied`() throws {
        let home = try Home()
        try home.fixture.folder(".ssh")
        let sneaky = home.fixture.root.appending(path: "Library/Caches/com.example.app/../../Keychains/login.keychain-db")
        #expect(home.policy.check(sneaky).isDenied)
        let escape = home.fixture.root.appending(path: "Library/Caches/com.example.app/../../../.ssh/id_rsa")
        #expect(home.policy.check(escape).isDenied)
    }

    @Test func `symlinked parent resolving into protected dir is denied`() throws {
        let home = try Home()
        let ssh = try home.fixture.folder(".ssh")
        try home.fixture.file(".ssh/id_rsa", size: 4)
        try home.fixture.symlink("Library/Caches/com.example.app/keys", to: ssh)
        #expect(try home.check("Library/Caches/com.example.app/keys/id_rsa").isDenied)
        let viaDotDot = home.fixture.root.appending(path: "Library/Caches/com.example.app/keys/../.ssh/id_rsa")
        #expect(home.policy.check(viaDotDot).isDenied)
        #expect(try home.check("Library/Caches/com.example.app/keys") == .allowed)
    }

    @Test func `custom artifact predicate is honored`() throws {
        let home = try Home(isKnownArtifact: { $0.lastPathComponent == "src" })
        #expect(try home.check("Code/app/src") == .allowed)
        #expect(try home.check("Code/app/node_modules").isDenied)
    }

    @Test func `unparsable never touch pattern denies every path`() throws {
        let home = try Home(neverTouch: ["~/Work", "~/a[b]"])
        #expect(try home.check("Library/Caches/com.example.app")
            == .denied("Never Touch pattern ~/a[b] could not be read, so everything is protected until it is fixed"))
        #expect(try home.check("big.iso").isDenied)
    }

    @Test func `database folder outside home is denied`() throws {
        let fixture = try FixtureBuilder(name: "ProtectionDB")
        let home = try fixture.folder("home")
        let databaseURL = try fixture.url("dev/macsentry.sqlite")
        let policy = DefaultProtectionPolicy(homeURL: home, databaseURL: databaseURL)
        #expect(policy.check(databaseURL).isDenied)
        #expect(try policy.check(fixture.url("dev")).isDenied)
        #expect(try policy.check(fixture.url("dev/macsentry.sqlite-wal")).isDenied)
    }

    @Test func `database folder containing home only protects database files`() throws {
        let fixture = try FixtureBuilder(name: "ProtectionDevDB")
        let home = try fixture.folder("root")
        try fixture.folder("root/Library/Caches/x")
        let policy = try DefaultProtectionPolicy(homeURL: home, databaseURL: fixture.url("macsentry.sqlite"))
        #expect(try policy.check(fixture.url("macsentry.sqlite")).isDenied)
        #expect(try policy.check(fixture.url("root/Library/Caches/x")) == .allowed)
    }
}

extension ProtectionVerdict {
    var isDenied: Bool {
        if case .denied = self {
            return true
        }
        return false
    }
}
