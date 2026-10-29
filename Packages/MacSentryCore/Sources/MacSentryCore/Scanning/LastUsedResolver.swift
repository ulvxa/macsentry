import CoreServices
import Foundation

public protocol LastUsedResolver: Sendable {
    func lastUsed(for urls: [URL]) async -> [URL: Date]
}

public struct SpotlightLastUsedResolver: LastUsedResolver {
    public init() {}

    public func lastUsed(for urls: [URL]) async -> [URL: Date] {
        var dates: [URL: Date] = [:]
        for (index, url) in urls.enumerated() {
            if index.isMultiple(of: 64) {
                if Task.isCancelled {
                    break
                }
                await Task.yield()
            }
            guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
                  let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            else { continue }
            dates[url] = date
        }
        return dates
    }
}

public struct FixedLastUsedResolver: LastUsedResolver {
    public let dates: [URL: Date]

    public init(_ dates: [URL: Date] = [:]) {
        self.dates = dates
    }

    public func lastUsed(for urls: [URL]) async -> [URL: Date] {
        let wanted = Set(urls.map(\.storagePath))
        return dates.filter { wanted.contains($0.key.storagePath) }
    }
}
