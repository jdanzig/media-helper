import Foundation
import UserNotifications
import UIKit

/// Manages the "download complete" local notification.
///
/// Notification is only fired when the app is not in the foreground — if
/// the user is watching the progress bar, the in-app banner is sufficient.
/// If the app is backgrounded or the screen is locked, a standard system
/// notification appears with the video title (if known).
@MainActor
final class DownloadNotifier {
    static let shared = DownloadNotifier()
    private init() {}

    /// Request notification permission. Called once before the first
    /// download. Safe to call multiple times — after the first, the OS
    /// returns the stored authorization status without showing a prompt.
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    /// Post a "saved to Photos" notification — but only if the app is
    /// currently backgrounded or inactive (i.e. the user left the app
    /// while the download was running).
    func notifyIfBackgrounded(title: String?) {
        guard applicationState != .active else { return }

        let content = UNMutableNotificationContent()
        content.title = "Download Complete"
        content.body = title.map { "\"\($0)\" saved to Photos." }
                     ?? "Video saved to Photos."
        content.sound = .default

        // nil trigger = deliver immediately
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Private

    /// Isolated read of UIApplication.shared.applicationState.
    /// `UIApplication` is `@MainActor`-bound, so we access it here rather
    /// than scattering nonisolated workarounds throughout the codebase.
    private var applicationState: UIApplication.State {
        UIApplication.shared.applicationState
    }
}
