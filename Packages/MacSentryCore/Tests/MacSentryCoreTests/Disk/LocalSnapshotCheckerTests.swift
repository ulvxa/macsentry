import Foundation
import Testing
@testable import MacSentryCore

struct LocalSnapshotCheckerTests {
    @Test func `tmutil output counts only snapshot names`() {
        let output = """
        Snapshots for disk /:
        com.apple.TimeMachine.2026-10-28-101500.local
        com.apple.os.update-4F1C2B3A
          com.apple.TimeMachine.2026-10-29-091200.local

        """
        #expect(TmutilLocalSnapshotChecker.parseSnapshotCount(output) == 3)
    }

    @Test func `tmutil output without snapshots counts zero`() {
        #expect(TmutilLocalSnapshotChecker.parseSnapshotCount("Snapshots for disk /:\n") == 0)
        #expect(TmutilLocalSnapshotChecker.parseSnapshotCount("") == 0)
    }

    @Test func `the stub returns its count or its typed error`() async throws {
        #expect(try await StubLocalSnapshotChecker(count: 2).localSnapshotCount() == 2)
        await #expect(throws: LocalSnapshotError.timedOut) {
            _ = try await StubLocalSnapshotChecker(error: .timedOut).localSnapshotCount()
        }
    }

    @Test func `the concrete checker targets tmutil on the boot volume with a 3 second timeout`() {
        let checker = TmutilLocalSnapshotChecker()
        #expect(checker.executableURL.path(percentEncoded: false) == "/usr/bin/tmutil")
        #expect(checker.volumeURL.path(percentEncoded: false) == "/")
        #expect(checker.timeout == .seconds(3))
    }
}
