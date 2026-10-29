import Foundation
import MacSentryCore
import Testing

struct AppEnvironmentTests {
    private let fakeHome = URL(filePath: "/Users/tester", directoryHint: .isDirectory)

    @Test func `defaults without arguments`() {
        let environment = AppEnvironment(arguments: ["/Applications/MacSentry.app/Contents/MacOS/MacSentry"], realHomeURL: fakeHome)
        #expect(environment.scanRoot == nil)
        #expect(environment.isDryRun == false)
        #expect(environment.databasePathOverride == nil)
        #expect(environment.homeURL == fakeHome)
        #expect(environment.databaseURL.path(percentEncoded: false)
            == "/Users/tester/Library/Application Support/MacSentry/macsentry.sqlite")
    }

    @Test func `parses all launch arguments`() {
        let environment = AppEnvironment(arguments: [
            "MacSentry",
            "-NSDocumentRevisionsDebugMode", "YES",
            "-MacSentryScanRoot", "/tmp/fixture/home",
            "-MacSentryDryRun", "YES",
            "-MacSentryDatabasePath", "/tmp/macsentry-p0/x.sqlite",
        ], realHomeURL: fakeHome)
        #expect(environment.scanRoot?.path(percentEncoded: false) == "/tmp/fixture/home/")
        #expect(environment.homeURL == environment.scanRoot)
        #expect(environment.isDryRun)
        #expect(environment.databaseURL.path(percentEncoded: false) == "/tmp/macsentry-p0/x.sqlite")
        #expect(environment.databaseURL == environment.databasePathOverride)
    }

    @Test(arguments: [("YES", true), ("yes", true), ("true", true), ("1", true), ("NO", false), ("0", false), ("maybe", false)])
    func `parses dry run flag`(_ value: String, _ expected: Bool) {
        let environment = AppEnvironment(arguments: ["app", "-MacSentryDryRun", value], realHomeURL: fakeHome)
        #expect(environment.isDryRun == expected)
    }

    @Test func `ignores key without value and empty values`() {
        let trailing = AppEnvironment(arguments: ["app", "-MacSentryScanRoot"], realHomeURL: fakeHome)
        #expect(trailing.scanRoot == nil)
        #expect(trailing.homeURL == fakeHome)
        let empty = AppEnvironment(arguments: ["app", "-MacSentryDatabasePath", ""], realHomeURL: fakeHome)
        #expect(empty.databasePathOverride == nil)
    }

    @Test func `release builds ignore scan root and database overrides but keep dry run`() {
        let environment = AppEnvironment(arguments: [
            "MacSentry",
            "-MacSentryScanRoot", "/tmp/fixture/home",
            "-MacSentryDryRun", "YES",
            "-MacSentryDatabasePath", "/tmp/macsentry-p0/x.sqlite",
        ], realHomeURL: fakeHome, allowsDevelopmentOverrides: false)
        #expect(environment.scanRoot == nil)
        #expect(environment.databasePathOverride == nil)
        #expect(environment.homeURL == fakeHome)
        #expect(environment.databaseURL.path(percentEncoded: false)
            == "/Users/tester/Library/Application Support/MacSentry/macsentry.sqlite")
        #expect(environment.isDryRun)
    }

    @Test func `debug test builds honor development overrides by default`() {
        #expect(AppEnvironment.allowsDevelopmentOverrides)
    }

    @Test func `standardizes paths`() {
        let environment = AppEnvironment(arguments: ["app", "-MacSentryScanRoot", "/tmp/a/../b"], realHomeURL: fakeHome)
        #expect(environment.scanRoot?.path(percentEncoded: false) == "/tmp/b/")
    }
}
