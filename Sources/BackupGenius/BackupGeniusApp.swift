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
        lifecycle.coordinator = model.coordinator
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
                Button("新手引导…") { model.setup = .guide }
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
            Label("Backup Genius", systemImage: model.menuSymbol)
                .accessibilityLabel("Backup Genius，\(model.menuStatus)")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            AppSettings(model: model)
        }
    }
}

@MainActor
final class Lifecycle: NSObject, NSApplicationDelegate {
    var coordinator: BackupCoordinator?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }
        Task {
            await coordinator.finishAndClose()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

enum SetupMode: String, Identifiable {
    case guide, configure, existing, takeover
    var id: Self { self }
}

enum Page: String, CaseIterable, Identifiable {
    case overview, activity, history, disk
    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "备份"
        case .activity: "活动记录"
        case .history: "备份历史"
        case .disk: "硬盘检测"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "externaldrive"
        case .activity: "list.bullet.rectangle"
        case .history: "clock.arrow.circlepath"
        case .disk: "externaldrive.badge.checkmark"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let coordinator: BackupCoordinator
    private(set) var engine: SyncEngine
    var folders: [BackupFolderStatus] = []
    var selectedFolder: UUID?
    var runningFolder: UUID?
    var diskProgress: [String: SyncProgress] = [:]
    var media: [String: StorageMedium] = [:]
    var askOnConnect = true
    var backupPrompts: [BackupPrompt] = []
    var connectedDisks = Set<String>()
    var busy = false
    var job: BackupJob?
    var volume: VolumeInfo?
    var organizedStorage = false
    var sourceDevice: StorageDeviceInfo?
    var progress = SyncProgress()
    var activities: [Activity] = []
    var versions: [HistoryItem] = []
    var backupRuns: [BackupRun] = []
    var restorePoints: [RestorePoint] = []
    var healthReport: DiskHealthReport?
    var speedReport: DiskSpeedReport?
    var diagnosing = false
    var setup: SetupMode?
    var page: Page = .overview
    var error: String?
    var restoring = false
    private var ejectRequested = false
    var loginEnabled = false
    var loginNeedsApproval = false

    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var notifications: [NSObjectProtocol] = []
    @ObservationIgnored private var loadRecordsTask: Task<Void, Never>?
    @ObservationIgnored var openBackupWindow: (() -> Void)?
    @ObservationIgnored private lazy var backupNotifications = BackupNotifications(
        respond: { [weak self] id, backup in self?.respondToBackupPrompt(id, backup: backup) },
        showWindow: { [weak self] in self?.openBackupWindow?() }
    )

    init() {
        let appSupport = URL.applicationSupportDirectory.appending(path: "Backup Genius", directoryHint: .isDirectory)
        let coordinator = BackupCoordinator(storage: appSupport)
        self.coordinator = coordinator
        engine = coordinator.legacy
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification, NSWorkspace.didWakeNotification] {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { event in
                let path = event.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL ??
                    (event.userInfo?["NSDevicePath"] as? String).map { URL(filePath: $0) }
                let mounted = name == NSWorkspace.didMountNotification ? path : nil
                let unmounted = name == NSWorkspace.didUnmountNotification ? path : nil
                Task { await coordinator.volumesDidChange(mounted: mounted, unmounted: unmounted) }
            })
        }
        refreshLoginStatus()
        observer = Task { [weak self] in
            for await snapshot in await coordinator.updates() {
                guard let self else { return }
                self.folders = snapshot.folders
                self.runningFolder = snapshot.running
                self.diskProgress = snapshot.diskProgress
                self.media = snapshot.media
                self.busy = snapshot.busy
                self.askOnConnect = snapshot.askOnConnect
                self.connectedDisks = snapshot.connectedDisks
                if self.backupPrompts.map(\.id) != snapshot.backupPrompts.map(\.id) {
                    self.backupPrompts = snapshot.backupPrompts
                    self.backupNotifications.update(snapshot.backupPrompts)
                } else if !snapshot.backupPrompts.isEmpty {
                    self.backupPrompts = snapshot.backupPrompts
                }
                let selected = snapshot.folders.first(where: { $0.id == self.selectedFolder }) ?? snapshot.folders.first
                await self.show(selected)
            }
        }
        Task { [weak self] in
            do {
                try await coordinator.start()
                if await coordinator.presentation.folders.isEmpty, !UserDefaults.standard.bool(forKey: "guideOffered") {
                    UserDefaults.standard.set(true, forKey: "guideOffered")
                    self?.setup = .guide
                }
            }
            catch { self?.error = error.localizedDescription }
        }
    }

    private func show(_ folder: BackupFolderStatus?) async {
        let changed = job?.id != folder?.id
        if changed, let folder, let next = await coordinator.engine(for: folder.id) { engine = next }
        let snapshot = folder?.snapshot ?? coordinator.legacy.presentation
        let shouldLoad = changed || progress.lastRunID != snapshot.progress.lastRunID ||
            (progress.state.busy && !snapshot.progress.state.busy)
        selectedFolder = folder?.id
        job = snapshot.job
        volume = snapshot.volume
        progress = snapshot.progress
        organizedStorage = snapshot.organizedStorage
        sourceDevice = snapshot.sourceDevice
        if changed { activities = []; versions = []; backupRuns = []; restorePoints = []; healthReport = nil; speedReport = nil }
        if shouldLoad { loadRecords() }
    }

    func selectFolder(_ id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        selectedFolder = id
        Task { await show(folder) }
    }

    var displayedProgress: SyncProgress {
        guard let job, job.setID != nil else { return progress }
        if let runningFolder, let current = folders.first(where: { $0.id == runningFolder }),
           current.job.volumeID == job.volumeID {
            var state = current.snapshot.progress
            if busy, !state.state.busy { state.state = .checking }
            return state
        }
        if progress.state == .ejected, let summary = diskProgress[job.volumeID.uppercased()] { return summary }
        if volume == nil || progress.state == .paused || progress.state == .takeoverRequired { return progress }
        return diskProgress[job.volumeID.uppercased()] ?? progress
    }

    var selectedMapping: FolderMapping? { folders.first(where: { $0.id == selectedFolder })?.mapping }

    var menuStatus: String { backupPrompts.isEmpty ? displayedProgress.state.title : "等待确认备份" }
    var menuSymbol: String {
        if !backupPrompts.isEmpty || displayedProgress.state == .needsAttention { return "externaldrive.badge.exclamationmark" }
        return "externaldrive"
    }

    var canSync: Bool {
        job?.restoreOnly == false && selectedMapping?.enabled != false && !busy &&
            (volume != nil || selectedDiskConnected || progress.state == .needsAttention) &&
            !progress.state.busy && progress.state != .takeoverRequired &&
            progress.state != .paused && !restoring && !ejecting
    }
    var selectedDiskConnected: Bool { job.map { connectedDisks.contains($0.volumeID.uppercased()) } ?? false }
    var canPause: Bool { job?.restoreOnly == false && volume != nil && !restoring && !ejecting }
    var ejecting: Bool { ejectRequested || progress.state == .ejecting }
    var canEject: Bool { (volume != nil || selectedDiskConnected) && !restoring && !ejecting }
    var canRestore: Bool { (volume != nil || selectedDiskConnected) && !busy && !progress.state.busy && !restoring && !ejecting }

    func sync() {
        guard canSync, let id = job?.id else { return }
        Task { await coordinator.sync(id) }
    }

    func verify() {
        guard canSync, let id = job?.id else { return }
        Task { await coordinator.sync(id, verify: true) }
    }

    func togglePause() {
        guard canPause, let id = job?.id else { return }
        Task {
            if progress.state == .paused { await coordinator.resume(id) }
            else { await coordinator.pause() }
        }
    }

    func eject() {
        guard canEject, let id = job?.id else { return }
        ejectRequested = true
        Task {
            defer { ejectRequested = false }
            do { try await coordinator.eject(id) }
            catch { self.error = error.localizedDescription }
        }
    }

    func openFolder() {
        guard let job, let volume else { return }
        let folder = volume.mount.appending(path: job.targetRelativePath, directoryHint: .isDirectory)
        NSWorkspace.shared.open(folder)
    }

    func loadRecords() {
        guard page == .activity || page == .history else { return }
        loadRecordsTask?.cancel()
        let page = page
        let engine = engine
        loadRecordsTask = Task {
            do {
                if page == .activity {
                    let values = try await engine.activity()
                    if !Task.isCancelled { activities = values }
                } else {
                    let runs = try await engine.backupRuns()
                    let values = try await engine.history()
                    let points = try await engine.restorePoints()
                    if !Task.isCancelled {
                        backupRuns = runs
                        versions = values
                        restorePoints = points
                    }
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    func restore(_ id: UUID?, point: UUID? = nil) {
        guard canRestore, let job = job?.id else { return }
        Task {
            guard let folder = await chooseFolder(title: "选择恢复位置", prompt: "恢复到此处", canCreate: true),
                  canRestore else { return }
            restoring = true
            defer { restoring = false }
            do {
                let result = try await coordinator.restore(job, version: id, point: point, to: folder)
                NSWorkspace.shared.activateFileViewerSelecting([result])
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func setAutomatic(_ value: Bool) {
        guard let id = job?.id else { return }
        Task {
            do { try await coordinator.setAutomatic(value, job: id) }
            catch { self.error = error.localizedDescription }
        }
    }

    func setAskOnConnect(_ value: Bool) {
        Task {
            do {
                try await coordinator.setAskOnConnect(value)
                if value { await backupNotifications.requestPermission() }
            } catch { self.error = error.localizedDescription }
        }
    }

    func requestBackupNotificationPermission() async {
        if askOnConnect { await backupNotifications.requestPermission() }
    }

    func respondToBackupPrompt(_ id: UUID, backup: Bool) {
        if backup, let prompt = backupPrompts.first(where: { $0.id == id }), job?.volumeID.uppercased() != prompt.volumeID,
           let folder = folders.first(where: { $0.job.volumeID.uppercased() == prompt.volumeID &&
               !$0.job.restoreOnly && $0.mapping?.enabled != false }) {
            selectFolder(folder.id)
        }
        Task { await coordinator.respondToBackupPrompt(id, backup: backup) }
    }

    func setEjectAfterBackup(_ value: Bool) {
        guard let id = job?.id else { return }
        Task {
            do { try await coordinator.setEjectAfterBackup(value, job: id) }
            catch { self.error = error.localizedDescription }
        }
    }

    func setMappingEnabled(_ enabled: Bool) {
        guard let id = job?.id else { return }
        Task {
            do { try await coordinator.setEnabled(enabled, job: id) }
            catch { self.error = error.localizedDescription }
        }
    }

    func diagnose(speed: Bool) {
        guard let id = job?.id, !busy, !diagnosing, selectedDiskConnected else { return }
        diagnosing = true
        Task {
            defer { diagnosing = false }
            do {
                let (health, measurement) = try await coordinator.diagnose(id, speed: speed)
                guard self.job?.id == id else { return }
                healthReport = health
                if let measurement { speedReport = measurement }
            } catch { self.error = error.localizedDescription }
        }
    }

    func setMedium(_ value: StorageMedium?, device: StorageDeviceInfo) {
        Task {
            do { try await coordinator.setMedium(value, device: device) }
            catch { self.error = error.localizedDescription }
        }
    }

    func organizeBackupDirectory() {
        Task {
            guard let disk = await chooseFolder(title: "授权存放备份记录的硬盘根目录", prompt: "授权",
                                                startingAt: volume?.mount) else { return }
            do { try await engine.organizeBackup(on: disk) }
            catch { self.error = error.localizedDescription }
        }
    }

    func setExistingFilesPolicy(_ policy: ExistingFilesPolicy) {
        Task {
            do { try await engine.setExistingFilesPolicy(policy) }
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
func chooseFolder(title: String, prompt: String, canCreate: Bool = false, startingAt: URL? = nil) async -> URL? {
    await chooseFolders(title: title, prompt: prompt, canCreate: canCreate, startingAt: startingAt, multiple: false).first
}

@MainActor
func chooseFolders(title: String, prompt: String, canCreate: Bool = false, startingAt: URL? = nil,
                   multiple: Bool = true) async -> [URL] {
    let panel = NSOpenPanel()
    if let startingAt { panel.directoryURL = startingAt }
    panel.title = title
    panel.prompt = prompt
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = canCreate
    panel.allowsMultipleSelection = multiple
    return await panel.begin() == .OK ? panel.urls : []
}

struct MenuControls: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        Text(model.menuStatus)
        if model.displayedProgress.state == .syncing && model.displayedProgress.planned > 0 {
            Text(backupTiming(model.displayedProgress))
        }
        if let job = model.job {
            Text("\(model.volume?.name ?? job.volumeName) · \(job.format.name)")
        }
        Divider()
        ForEach(model.backupPrompts) { prompt in
            Menu(prompt.volumeName) {
                Button("立即备份") { model.respondToBackupPrompt(prompt.id, backup: true) }
                Button("稍后") { model.respondToBackupPrompt(prompt.id, backup: false) }
            }
        }
        if !model.backupPrompts.isEmpty { Divider() }
        Button("打开 Backup Genius") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("立即同步", action: model.sync).disabled(!model.canSync)
        Button(model.progress.state == .paused ? "继续备份" : "暂停备份", action: model.togglePause)
            .disabled(!model.canPause)
        Button("安全推出", action: model.eject).disabled(!model.canEject)
        Button("新手引导…") {
            openWindow(id: "main")
            model.setup = .guide
            NSApp.activate()
        }
        .disabled(model.busy)
        Divider()
        SettingsLink { Text("设置…") }
        Button("退出 Backup Genius") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
