import AppKit
import Foundation
import UserNotifications

enum NotificationAuthorization: Equatable {
    case notDetermined, authorized, denied
}

protocol LowSpaceNotifier: Sendable {
    func authorization() async -> NotificationAuthorization
    func requestAuthorization() async -> NotificationAuthorization
    func postLowSpace(freeBytes: Int64, thresholdBytes: Int64) async
    func openSystemSettings() async
}

enum LowSpaceNotification {
    static let categoryID = "dev.macsentry.lowSpace"
    static let reviewActionID = "dev.macsentry.lowSpace.review"
    static let requestID = "dev.macsentry.lowSpace.request"

    static func body(freeBytes: Int64, thresholdBytes: Int64) -> String {
        "\(MenuBarFormatting.compactFree(freeBytes)) free, below your \(MenuBarFormatting.compactFree(thresholdBytes)) limit. "
            + "Review what can be cleaned up."
    }
}

struct SystemLowSpaceNotifier: LowSpaceNotifier {
    private var center: UNUserNotificationCenter {
        .current()
    }

    func authorization() async -> NotificationAuthorization {
        await Self.map(center.notificationSettings().authorizationStatus)
    }

    func requestAuthorization() async -> NotificationAuthorization {
        registerCategory()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await authorization()
    }

    func postLowSpace(freeBytes: Int64, thresholdBytes: Int64) async {
        registerCategory()
        let content = UNMutableNotificationContent()
        content.title = "Low disk space"
        content.body = LowSpaceNotification.body(freeBytes: freeBytes, thresholdBytes: thresholdBytes)
        content.categoryIdentifier = LowSpaceNotification.categoryID
        content.sound = .default
        let request = UNNotificationRequest(identifier: LowSpaceNotification.requestID, content: content, trigger: nil)
        try? await center.add(request)
    }

    func openSystemSettings() async {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)")
            ?? URL(filePath: "/System/Applications/System Settings.app")
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }

    private func registerCategory() {
        let review = UNNotificationAction(identifier: LowSpaceNotification.reviewActionID, title: "Review", options: [.foreground])
        let category = UNNotificationCategory(identifier: LowSpaceNotification.categoryID, actions: [review], intentIdentifiers: [])
        center.setNotificationCategories([category])
    }

    private static func map(_ status: UNAuthorizationStatus) -> NotificationAuthorization {
        switch status {
        case .authorized, .provisional, .ephemeral: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }
}

struct SilentLowSpaceNotifier: LowSpaceNotifier {
    func authorization() async -> NotificationAuthorization {
        .denied
    }

    func requestAuthorization() async -> NotificationAuthorization {
        .denied
    }

    func postLowSpace(freeBytes _: Int64, thresholdBytes _: Int64) async {}

    func openSystemSettings() async {}
}

@MainActor
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate {
    var onReview: (@MainActor () -> Void)?
    private var reviewPending = false

    func deliverPending() {
        guard reviewPending else { return }
        reviewPending = false
        onReview?()
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
    ) async {
        let action = response.actionIdentifier
        guard action == LowSpaceNotification.reviewActionID || action == UNNotificationDefaultActionIdentifier else { return }
        await handleReview()
    }

    private func handleReview() {
        if let onReview {
            onReview()
        } else {
            reviewPending = true
        }
    }
}
