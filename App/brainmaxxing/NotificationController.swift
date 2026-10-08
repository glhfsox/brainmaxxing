import DigestCore
import Foundation
import UserNotifications

/// The daily "Digest ready" / "No digest yet - run now?" notification.
/// Posted at a `--hidden` launch (launchd, `show_at`) and, when the app is already running at `show_at`, by an
/// in-app timer: `open -g ... --args --hidden` does not deliver arguments to a running app. Once per day.
@MainActor
final class NotificationController: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationController()

    private static let noDigestCategory = "NO_DIGEST"
    private static let runNowAction = "RUN_NOW"
    private static let lastPostedKey = "lastDailyNotificationDate"

    private weak var model: AppModel?
    private var dailyTask: Task<Void, Never>?
    private var center: UNUserNotificationCenter { .current() }

    func install(model: AppModel) {
        self.model = model
        center.delegate = self
        let runNow = UNNotificationAction(identifier: Self.runNowAction, title: "Run now", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.noDigestCategory, actions: [runNow], intentIdentifiers: []),
        ])
    }

    /// Asks once (the system remembers the answer).
    func requestAuthorizationIfNeeded() async {
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func postDailyIfNeeded() async {
        guard let model else { return }
        let today = model.today
        guard UserDefaults.standard.string(forKey: Self.lastPostedKey) != today else { return }
        await model.reloadList()
        let item = model.digests.first { $0.date == today }
        let content = UNMutableNotificationContent()
        if let item {
            content.title = "Digest ready"
            content.body = item.empty ? item.title : "\(item.title) - \(item.paperCount) papers\(item.partial ? " (partial)" : "")"
        } else {
            content.title = "No digest yet"
            content.body = "The nightly run did not produce a digest today. Run now?"
            content.categoryIdentifier = Self.noDigestCategory
        }
        content.userInfo = ["date": today]
        do {
            try await center.add(UNNotificationRequest(identifier: "daily-\(today)", content: content, trigger: nil))
            UserDefaults.standard.set(today, forKey: Self.lastPostedKey)
        } catch {
            model.errorMessage = "Notification failed: \(error.localizedDescription)"
        }
    }

    /// Sleeps until the next `show_at` and posts, for as long as the app runs.
    func scheduleDaily() {
        dailyTask?.cancel()
        dailyTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let hour = self?.model?.config.schedule.showAt,
                      let next = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: hour, minute: 0, second: 5),
                                                           matchingPolicy: .nextTime)
                else { return }
                try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
                if Task.isCancelled { return }
                await self?.postDailyIfNeeded()
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let date = response.notification.request.content.userInfo["date"] as? String
        await MainActor.run {
            guard let model = self.model else { return }
            switch action {
            case Self.runNowAction:
                model.showMainWindow(date: date)
                model.requestManualRun(categories: nil)
            default:
                model.showMainWindow(date: date)
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
