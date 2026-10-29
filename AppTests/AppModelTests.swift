import Foundation
import MacSentryCore
import MacSentryTestSupport
import Testing
@testable import MacSentry

@MainActor
struct AppModelTests {
    @Test func `opens database at override path`() async throws {
        let fixture = try FixtureBuilder(name: "AppModel")
        let databaseURL = try fixture.url("db/macsentry.sqlite")
        let environment = AppEnvironment(
            arguments: [
                "MacSentry",
                "-MacSentryScanRoot",
                fixture.root.path(percentEncoded: false),
                "-MacSentryDryRun",
                "YES",
                "-MacSentryDatabasePath",
                databaseURL.path(percentEncoded: false),
            ],
            realHomeURL: fixture.root,
        )
        let model = AppModel(environment: environment)
        await model.openDatabase()
        #expect(model.database?.fileURL == databaseURL)
        #expect(model.alert == nil)
        #expect(FileManager.default.fileExists(atPath: databaseURL.path(percentEncoded: false)))
    }
}
