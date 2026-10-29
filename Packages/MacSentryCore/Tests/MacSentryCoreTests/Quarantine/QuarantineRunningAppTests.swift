import Foundation
import MacSentryTestSupport
import Testing
@testable import MacSentryCore

struct QuarantineRunningAppTests {
    @Test func `the running app bundle, its contents and folders holding it are never moved`() async throws {
        let harness = try QuarantineHarness(name: "QuarantineRunningApp")
        let derivedData = try harness.fixture.folder("home/Library/Developer/Xcode/DerivedData")
        let products = try harness.fixture.folder("home/Library/Developer/Xcode/DerivedData/MacSentry-abc/Build/Products/Debug")
        let app = try harness.fixture.folder("home/Library/Developer/Xcode/DerivedData/MacSentry-abc/Build/Products/Debug/MacSentry.app")
        let binary = try harness.fixture.file(
            "home/Library/Developer/Xcode/DerivedData/MacSentry-abc/Build/Products/Debug/MacSentry.app/Contents/MacOS/MacSentry",
            size: 4096,
        )
        let other = try harness.fixture.folder("home/Library/Developer/Xcode/DerivedData/Other-def")
        try harness.fixture.file("home/Library/Developer/Xcode/DerivedData/Other-def/Build/out.o", size: 4096)
        let candidates = try [
            harness.candidate(derivedData),
            harness.candidate(products),
            harness.candidate(app, kind: .package),
            harness.candidate(binary, kind: .file),
            harness.candidate(other),
        ]

        let result = await harness.makeService(runningAppURL: app).quarantine(candidates)

        #expect(result.failed.map(\.path) == [derivedData, products, app, binary])
        #expect(result.failed.allSatisfy { $0.reason == .appRunning })
        #expect(result.moved.map(\.originalURL) == [other])
        #expect(exists(app) && exists(binary))
        #expect(!exists(other))
    }
}
