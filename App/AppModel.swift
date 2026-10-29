import Foundation
import MacSentryCore
import Observation

struct AppAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

@Observable
@MainActor
final class AppModel {
    let environment: AppEnvironment
    var selection: SidebarItem? = .overview
    var alert: AppAlert?
    private(set) var database: Database?
    private var isOpeningDatabase = false

    init(environment: AppEnvironment = AppEnvironment()) {
        self.environment = environment
    }

    func openDatabase() async {
        guard database == nil, !isOpeningDatabase else { return }
        isOpeningDatabase = true
        defer { isOpeningDatabase = false }
        let url = environment.databaseURL
        do {
            let opened = try await Task.detached(priority: .userInitiated) {
                try Database.open(at: url)
            }.value
            database = opened
            if let backup = opened.corruptBackupURL {
                alert = AppAlert(
                    title: "Database Was Reset",
                    message: "MacSentry found a damaged database and moved it aside to \(backup.lastPathComponent). "
                        + "Quarantined files are untouched and their manifests on disk remain the record.",
                )
            }
        } catch {
            alert = AppAlert(title: "Database Unavailable", message: error.localizedDescription)
        }
    }
}
