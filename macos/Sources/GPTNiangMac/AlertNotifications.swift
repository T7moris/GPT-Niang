import UserNotifications

@MainActor
protocol AlertNotifications {
    func authorize(request: Bool, completion: @escaping @MainActor (Bool) -> Void)
    func send(title: String, body: String, completion: @escaping @MainActor (Bool) -> Void)
}

@MainActor
final class SystemAlertNotifications: NSObject, AlertNotifications, UNUserNotificationCenterDelegate {
    // Creating a model or monitoring task events must not initialize system
    // notifications. Access the OS service only when quota delivery needs it.
    private lazy var center: UNUserNotificationCenter = {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        return center
    }()
    func authorize(request: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        Task { @MainActor in
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined && request {
                let granted = (try? await center.requestAuthorization(options: [.alert])) ?? false
                completion(granted)
            } else {
                completion(settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
            }
        }
    }
    func send(title: String, body: String, completion: @escaping @MainActor (Bool) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        // Optional audio is handled locally at the user's selected volume.
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            Task { @MainActor in completion(error == nil) }
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
