import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarEnabled: @MainActor () -> Bool = { true }
    var onWake: (@MainActor () async -> Void)?
    let notificationResponder = NotificationResponder()
    private var wakeTask: Task<Void, Never>?

    nonisolated static func shouldTerminateAfterLastWindowClosed(menuBarEnabled: Bool) -> Bool {
        !menuBarEnabled
    }

    func applicationDidFinishLaunching(_: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            UNUserNotificationCenter.current().delegate = notificationResponder
        }
        wakeTask = Task { [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                await self?.onWake?()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        Self.shouldTerminateAfterLastWindowClosed(menuBarEnabled: menuBarEnabled())
    }

    func connect(to model: AppModel) {
        menuBarEnabled = { model.settings.menuBarEnabled }
        onWake = { await model.menuBar.pressure.handleWake() }
        notificationResponder.onReview = {
            model.selection = .overview
            model.menuBar.openMainWindow()
        }
        notificationResponder.deliverPending()
    }
}
