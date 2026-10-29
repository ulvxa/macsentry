import Foundation
import MacSentryTestSupport
import Synchronization
import Testing
@testable import MacSentryCore

struct PermissionServiceTests {
    private func service(_ fixture: FixtureBuilder, tcc: String = "missing/TCC.db") throws -> SystemPermissionService {
        try SystemPermissionService(homeURL: fixture.root, tccDatabaseURL: fixture.url(tcc), openURL: { _ in })
    }

    @Test func `readable stocks container means granted`() throws {
        let fixture = try FixtureBuilder(name: "FDAStocks")
        try fixture.file("Library/Containers/com.apple.stocks/Data/x", size: 1)
        #expect(try service(fixture).hasFullDiskAccess())
    }

    @Test func `readable TCC database means granted and is not modified`() throws {
        let fixture = try FixtureBuilder(name: "FDATCC")
        let tcc = try fixture.file("tcc/TCC.db", size: 64, modified: Date(timeIntervalSince1970: 1_000_000))
        #expect(try service(fixture, tcc: "tcc/TCC.db").hasFullDiskAccess())
        let attributes = try FileManager.default.attributesOfItem(atPath: tcc.path(percentEncoded: false))
        #expect(attributes[.modificationDate] as? Date == Date(timeIntervalSince1970: 1_000_000))
        #expect(attributes[.size] as? Int == 64)
    }

    @Test func `neither probe succeeding means missing`() throws {
        let fixture = try FixtureBuilder(name: "FDAMissing")
        #expect(try !service(fixture).hasFullDiskAccess())
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appending(path: "Library").path(percentEncoded: false)))
    }

    @Test func `open settings passes privacy pane URL`() throws {
        let fixture = try FixtureBuilder(name: "FDAOpen")
        let opened = Mutex<[URL]>([])
        let service = SystemPermissionService(homeURL: fixture.root, openURL: { url in opened.withLock { $0.append(url) } })
        service.openFullDiskAccessSettings()
        #expect(opened.withLock { $0 }.map(\.absoluteString)
            == ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"])
    }

    @Test func `double reports configured state and counts opens`() {
        let double = PermissionServiceDouble(granted: false)
        #expect(!double.hasFullDiskAccess())
        double.granted = true
        double.openFullDiskAccessSettings()
        #expect(double.hasFullDiskAccess())
        #expect(double.openCount == 1)
    }
}
