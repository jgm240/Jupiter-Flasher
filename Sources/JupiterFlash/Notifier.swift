// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import UserNotifications

/// "Done" / "Failed" notifications. Only works when running as a real .app bundle (not via `swift run`).
enum Notifier {
    private static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts only when the app isn't in the foreground (otherwise the on-screen status is enough).
    static func post(title: String, body: String) {
        guard available, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
