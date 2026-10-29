import Darwin
import Foundation

public enum MoveFailure: String, Error, Sendable, CaseIterable, LocalizedError {
    case protected, missing, appRunning, permissionDenied, locked, changedSinceScan,
         destinationExists, crossDevice, dataless, unknown

    public var errorDescription: String? {
        switch self {
        case .protected:
            "MacSentry's protection rules don't allow moving this item."
        case .missing:
            "The item no longer exists. It was probably deleted or moved after the scan."
        case .appRunning:
            "The app that owns this item is running. Quit the app and try again."
        case .permissionDenied:
            "MacSentry doesn't have permission to move this item. Check Full Disk Access in System Settings."
        case .locked:
            "The item is locked. Unlock it in Finder's Get Info window and try again."
        case .changedSinceScan:
            "The item changed since the last scan. Scan again before moving it."
        case .destinationExists:
            "Something already exists at the destination, so nothing was overwritten."
        case .crossDevice:
            "The item is on a different volume than the quarantine folder, so it was left in place."
        case .dataless:
            "The item is stored in the cloud and not downloaded, so moving it would free no space."
        case .unknown:
            "An unexpected error stopped the move, for example a path that is too long."
        }
    }

    init(errno code: Int32) {
        switch code {
        case ENOENT, ENOTDIR: self = .missing
        case EXDEV: self = .crossDevice
        case EACCES, EPERM, EROFS: self = .permissionDenied
        case EEXIST, ENOTEMPTY: self = .destinationExists
        default: self = .unknown
        }
    }
}

public enum EntryFailureReason: String, Error, Sendable, CaseIterable, LocalizedError {
    case notFound, missing, alreadyTrashed, alreadyRestored, destinationExists, permissionDenied,
         outsideQuarantine, dryRunMode, unknown

    public var errorDescription: String? {
        switch self {
        case .notFound:
            "This quarantine record no longer exists."
        case .missing:
            "The item is no longer in the quarantine folder. It may have been moved or deleted in Finder."
        case .alreadyTrashed:
            "The item is already in the Trash. To get it back, use Put Back in the Finder Trash."
        case .alreadyRestored:
            "The item was already restored to its original location."
        case .destinationExists:
            "Something now exists at the original location, so the item was not restored."
        case .permissionDenied:
            "MacSentry doesn't have permission to move this item. Check Full Disk Access in System Settings."
        case .outsideQuarantine:
            "The recorded location is outside the quarantine folder, so MacSentry won't touch it."
        case .dryRunMode:
            "Dry run is on, so nothing was changed on disk."
        case .unknown:
            "An unexpected error stopped the operation."
        }
    }

    init(errno code: Int32) {
        switch code {
        case ENOENT, ENOTDIR: self = .missing
        case EACCES, EPERM, EROFS: self = .permissionDenied
        case EEXIST, ENOTEMPTY: self = .destinationExists
        default: self = .unknown
        }
    }
}
