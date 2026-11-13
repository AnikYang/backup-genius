import BackupCore
import UserNotifications

@MainActor
final class BackupNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let category = "backup-disk-connected"
    private let backupAction = "backup-now"
    private let laterAction = "backup-later"
    private var active = Set<UUID>()
    private var permissionRequest: Task<Void, Never>?
    private let respond: @MainActor (UUID, Bool) -> Void
    private let showWindow: @MainActor () -> Void

    init(respond: @escaping @MainActor (UUID, Bool) -> Void, showWindow: @escaping @MainActor () -> Void) {
        self.respond = respond
        self.showWindow = showWindow
        super.init()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: category,
            actions: [UNNotificationAction(identifier: backupAction, title: "立即备份"),
                      UNNotificationAction(identifier: laterAction, title: "稍后")],
            intentIdentifiers: []
        )])
    }

    func requestPermission() async {
        if let permissionRequest { await permissionRequest.value; return }
        let request = Task {
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert])
        }
        permissionRequest = request
        await request.value
        permissionRequest = nil
    }

    func update(_ prompts: [BackupPrompt]) {
        let ids = Set(prompts.map(\.id))
        guard active != ids else { return }
        let expired = active.subtracting(ids).map(\.uuidString)
        center.removePendingNotificationRequests(withIdentifiers: expired)
        center.removeDeliveredNotifications(withIdentifiers: expired)
        let fresh = prompts.filter { !active.contains($0.id) }
        active = ids
        guard !fresh.isEmpty else { return }
        Task {
            await requestPermission()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            for prompt in fresh where active.contains(prompt.id) {
                let content = UNMutableNotificationContent()
                content.title = "已连接备份硬盘"
                content.body = "要将 \(prompt.folderCount) 个文件夹备份到「\(prompt.volumeName)」吗？"
                content.categoryIdentifier = category
                let id = prompt.id.uuidString
                try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
                if !active.contains(prompt.id) { center.removeDeliveredNotifications(withIdentifiers: [id]) }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             didReceive response: UNNotificationResponse) async {
        guard let id = UUID(uuidString: response.notification.request.identifier) else { return }
        let action = response.actionIdentifier
        await MainActor.run {
            guard active.contains(id) else { return }
            if action == backupAction || action == laterAction { respond(id, action == backupAction) }
            if action == UNNotificationDefaultActionIdentifier { showWindow() }
        }
    }
}
