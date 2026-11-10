import SwiftUI
import AppKit
import ServiceManagement
import BackupCore

// Use the system property wrapper on toolchains without the SwiftUI macro plugin.
typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct BackupGeniusApp: App {
    @NSApplicationDelegateAdaptor private var lifecycle: Lifecycle
    @ViewState private var model: AppModel

    init() {
        let model = AppModel()
        _model = ViewState(wrappedValue: model)
        lifecycle.engine = model.engine
    }

    var body: some Scene {
        Window("Backup Genius", id: "main") {
            MainWindow(model: model)
                .frame(minWidth: 800, minHeight: 540)
        }
        .defaultSize(width: 1000, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("设置备份…") { model.setup = .configure }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("打开已有备份…") { model.setup = .existing }
            }
            CommandMenu("备份") {
                Button("立即同步", action: model.sync)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.canSync)
                Button(model.progress.state == .paused ? "继续备份" : "暂停备份", action: model.togglePause)
                    .disabled(!model.canPause)
                Button("校验备份…", action: model.verify)
                    .disabled(!model.canSync)
                Divider()
                Button("安全推出", action: model.eject).disabled(!model.canEject)
            }
        }

        MenuBarExtra {
            MenuControls(model: model)
        } label: {
            Label("Backup Genius", systemImage: model.progress.state == .needsAttention ?
                  "externaldrive.badge.exclamationmark" : "externaldrive")
                .accessibilityLabel("Backup Genius，\(model.progress.state.title)")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            AppSettings(model: model)
        }
    }
}

@MainActor
final class Lifecycle: NSObject, NSApplicationDelegate {
    var engine: SyncEngine?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let engine else { return .terminateNow }
        Task {
            await engine.finishAndClose()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

enum SetupMode: String, Identifiable {
    case configure, existing, takeover
    var id: Self { self }
}

enum Page: String, CaseIterable, Identifiable {
    case overview, activity, history
    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "备份"
        case .activity: "活动记录"
        case .history: "历史版本"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "externaldrive"
        case .activity: "list.bullet.rectangle"
        case .history: "clock.arrow.circlepath"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let engine: SyncEngine
    var job: BackupJob?
    var volume: VolumeInfo?
    var progress = SyncProgress()
    var activities: [Activity] = []
    var versions: [HistoryItem] = []
    var setup: SetupMode?
    var page: Page = .overview
    var error: String?
    var restoring = false
    var ejecting = false
    var loginEnabled = false
    var loginNeedsApproval = false

    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored private var loadRecordsTask: Task<Void, Never>?

    init() {
        let appSupport = URL.applicationSupportDirectory.appending(path: "Backup Genius", directoryHint: .isDirectory)
        let engine = SyncEngine(storage: appSupport)
        self.engine = engine
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification, NSWorkspace.didWakeNotification] {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                engine.volumesDidChange()
            })
        }
        refreshLoginStatus()
        observer = Task { [weak self] in
            for await update in engine.updates() {
                guard let self else { return }
                let wasBusy = self.progress.state.busy
                let snapshot = engine.presentation
                self.progress = update
                self.job = snapshot.job
                self.volume = snapshot.volume
                if wasBusy && !update.state.busy { self.loadRecords() }
            }
        }
        Task { [weak self] in
            do { try await engine.start() }
            catch { self?.error = error.localizedDescription }
        }
    }

    var canSync: Bool {
        job?.restoreOnly == false && (volume != nil || progress.state == .needsAttention) &&
            !progress.state.busy && progress.state != .takeoverRequired &&
            progress.state != .paused && !restoring && !ejecting
    }
    var canPause: Bool { job?.restoreOnly == false && volume != nil && !restoring && !ejecting }
    var canEject: Bool { volume != nil && !restoring && !ejecting }
    var canRestore: Bool { volume != nil && !progress.state.busy && !restoring && !ejecting }

    func sync() {
        guard canSync else { return }
        Task { _ = try? await engine.syncNow() }
    }

    func verify() {
        guard canSync else { return }
        Task { _ = try? await engine.verify() }
    }

    func togglePause() {
        guard canPause else { return }
        if progress.state == .paused { engine.resume() } else { engine.pause() }
    }

    func eject() {
        guard canEject else { return }
        ejecting = true
        Task {
            defer { ejecting = false }
            let mount: URL
            do {
                mount = try await engine.prepareToEject()
            } catch {
                engine.volumesDidChange()
                self.error = error.localizedDescription
                return
            }
            do {
                try await BackupDisk.eject(mount)
            } catch {
                self.error = "已释放备份硬盘，可从 Finder 推出。\n\(error.localizedDescription)"
            }
        }
    }

    func openFolder() {
        guard let job, let volume else { return }
        let folder = volume.mount.appending(path: job.targetRelativePath, directoryHint: .isDirectory)
        NSWorkspace.shared.open(folder)
    }

    func loadRecords() {
        guard page != .overview else { return }
        loadRecordsTask?.cancel()
        let page = page
        loadRecordsTask = Task {
            do {
                if page == .activity {
                    let values = try await engine.activity()
                    if !Task.isCancelled { activities = values }
                } else {
                    let values = try await engine.history()
                    if !Task.isCancelled { versions = values }
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    func restore(_ id: UUID?) {
        guard canRestore else { return }
        Task {
            guard let folder = await chooseFolder(title: "选择恢复位置", prompt: "恢复到此处", canCreate: true) else { return }
            restoring = true
            defer { restoring = false }
            do {
                let result = try await engine.restore(id, to: folder)
                NSWorkspace.shared.activateFileViewerSelecting([result])
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func setAutomatic(_ value: Bool) {
        Task {
            do { try await engine.setAutomatic(value) }
            catch { self.error = error.localizedDescription }
        }
    }

    func setReuseMatchingFiles(_ value: Bool) {
        Task {
            do { try await engine.setReuseMatchingFiles(value) }
            catch { self.error = error.localizedDescription }
        }
    }

    func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        loginEnabled = status == .enabled
        loginNeedsApproval = status == .requiresApproval
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            self.error = "无法更改登录项。\(error.localizedDescription)"
        }
        refreshLoginStatus()
    }
}

@MainActor
func chooseFolder(title: String, prompt: String, canCreate: Bool = false) async -> URL? {
    let panel = NSOpenPanel()
    panel.title = title
    panel.prompt = prompt
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = canCreate
    panel.allowsMultipleSelection = false
    return await panel.begin() == .OK ? panel.url : nil
}

struct MenuControls: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        Text(model.progress.state.title)
        if let job = model.job {
            Text("\(model.volume?.name ?? job.volumeName) · \(job.format.name)")
        }
        Divider()
        Button("打开 Backup Genius") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("立即同步", action: model.sync).disabled(!model.canSync)
        Button(model.progress.state == .paused ? "继续备份" : "暂停备份", action: model.togglePause)
            .disabled(!model.canPause)
        Button("安全推出", action: model.eject).disabled(!model.canEject)
        Divider()
        SettingsLink { Text("设置…") }
        Button("退出 Backup Genius") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
