import Foundation
import Observation
import ServiceManagement

enum LoginItemStatus: Equatable {
    case notRegistered, enabled, requiresApproval, notFound
}

@MainActor
protocol LoginItemService {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

struct SystemLoginItemService: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notRegistered
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@Observable
@MainActor
final class LoginItemController {
    @ObservationIgnored private let service: any LoginItemService
    @ObservationIgnored private let mirror: @MainActor (Bool) -> Void
    private(set) var status: LoginItemStatus
    private(set) var errorMessage: String?

    init(service: any LoginItemService = SystemLoginItemService(), mirror: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.service = service
        self.mirror = mirror
        status = service.status
    }

    var isOn: Bool {
        status == .enabled || status == .requiresApproval
    }

    var needsApproval: Bool {
        status == .requiresApproval
    }

    func refresh() {
        status = service.status
        mirror(isOn)
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}
