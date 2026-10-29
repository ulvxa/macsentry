import Foundation

public protocol Trasher: Sendable {
    func trash(_ url: URL) throws -> URL?
}

public struct SystemTrasher: Trasher {
    public init() {}

    public func trash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}
