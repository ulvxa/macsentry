import Foundation
import GRDB
import Testing
@testable import MacSentryCore

struct PipelineCancelTests {
    @Test func `control cancel mid scan keeps the stream open until the session is saved as cancelled`() async throws {
        let harness = try PipelineHarness("ControlCancel", finder: GatedDuplicateFinder())
        for index in 0 ..< 3 {
            try harness.fixture.file("Downloads/dup-\(index).bin", size: 2 * PipelineHarness.megabyte, fill: 0x64)
        }
        let control = ScanControl()
        let canceller = Task {
            for await _ in control.hashingProgress {
                return control.cancel()
            }
            return false
        }
        let service = harness.pipeline.makeService(options: ScanPipelineOptions(), control: control)
        let started = ContinuousClock.now
        let events = try await ScanTest.collect(service.scan(config: harness.pipeline.config(scanRoots: [])))

        #expect(await canceller.value)
        #expect(ContinuousClock.now - started < .seconds(20))
        #expect(ScanTest.summary(events) == nil)
        let sessions = try await harness.database.writer.read { try ScanSession.fetchAll($0) }
        #expect(sessions.map(\.status) == [.cancelled])
    }

    @Test func `control cancel before the scan starts never opens a session`() async throws {
        let harness = try PipelineHarness("ControlCancelEarly")
        let control = ScanControl()
        let service = harness.pipeline.makeService(options: ScanPipelineOptions(), control: control)
        let stream = service.scan(config: harness.pipeline.config(scanRoots: []))
        #expect(control.cancel())
        let events = try await ScanTest.collect(stream)

        #expect(events.isEmpty)
        #expect(try await harness.database.writer.read { try ScanSession.fetchCount($0) } == 0)
    }
}
