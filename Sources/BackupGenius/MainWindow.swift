import SwiftUI
import AppKit
import BackupCore

extension SyncState {
    var title: String {
        switch self {
        case .unconfigured: "尚未设置备份"
        case .disconnected: "等待硬盘"
        case .ready: "硬盘已连接"
        case .checking: "正在检查变化"
        case .syncing: "正在同步"
        case .recovering: "正在恢复中断的同步"
        case .savingPoint: "正在保存备份时间点"
        case .verifying: "正在校验备份"
        case .upToDate: "已同步"
        case .paused: "备份已暂停"
        case .needsAttention: "需要处理"
        case .takeoverRequired: "等待接管"
        case .ejecting: "正在安全推出"
        case .ejected: "硬盘已推出"
        }
    }

    var symbol: String {
        switch self {
        case .upToDate: "checkmark.shield"
        case .disconnected: "externaldrive.badge.minus"
        case .unconfigured, .ready: "externaldrive"
        case .checking, .verifying: "magnifyingglass"
        case .syncing, .recovering, .savingPoint: "arrow.triangle.2.circlepath"
        case .paused: "pause.circle"
        case .needsAttention: "exclamationmark.triangle"
        case .takeoverRequired: "arrow.left.arrow.right.circle"
        case .ejecting, .ejected: "eject"
        }
    }

    var color: Color {
        switch self {
        case .upToDate, .ejected: .green
        case .needsAttention, .takeoverRequired: .orange
        case .disconnected, .paused, .unconfigured: .secondary
        default: .accentColor
        }
    }
}

extension Activity.Kind {
    var title: String {
        switch self {
        case .added: "新增"
        case .updated: "修改"
        case .moved: "移动"
        case .deleted: "移入历史"
        case .issue: "需处理"
        case .recovered: "中断恢复"
        case .verified: "已校验"
        }
    }

    var symbol: String {
        switch self {
        case .added: "plus.circle"
        case .updated: "pencil.circle"
        case .moved: "arrow.right.circle"
        case .deleted: "archivebox"
        case .issue: "exclamationmark.circle"
        case .recovered: "arrow.uturn.backward.circle"
        case .verified: "checkmark.seal"
        }
    }
}

func byteCount(_ count: Int64) -> String {
    count == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}

func backupTiming(_ progress: SyncProgress) -> String {
    let rate = progress.writeBytesPerSecond.map { "\(byteCount(Int64(min(max(0, $0), 1e18))))/s" } ?? "测量中"
    if progress.processed >= progress.planned { return "写入速度 \(rate) · 正在收尾" }
    guard let seconds = progress.estimatedSecondsRemaining, seconds.isFinite else {
        return "写入速度 \(rate) · 剩余时间估算中"
    }
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .abbreviated
    formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute, .second] : [.second])
    formatter.maximumUnitCount = 2
    let duration = formatter.string(from: max(1, min(seconds.rounded(.up), 365 * 86400))) ?? "估算中"
    return "写入速度 \(rate) · 当前同步阶段约剩 \(duration)"
}

struct MainWindow: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: Binding<Page?>(get: { model.page }, set: { model.page = $0 ?? .overview })) {
                    Section("备份管理") {
                        ForEach(Page.allCases) { page in
                            Label(page.title, systemImage: page.symbol).tag(page)
                        }
                    }
                }
                .listStyle(.sidebar)
                Divider().padding(.horizontal, 14)
                SidebarDisk(name: model.selectedDiskName ?? "备份硬盘", volume: model.volume,
                            state: model.progress.state, connected: model.selectedDiskConnected, configured: model.job != nil)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 216, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if model.disks.count > 1 || showsFolderPicker {
                    selectionBar
                    Divider()
                }
                // Native tables can propose their ideal height in a split column.
                // Keep each page within the space left after the folder bar.
                GeometryReader { geometry in
                    Group {
                        switch model.page {
                        case .overview: Overview(model: model)
                        case .activity: ActivityScreen(model: model)
                        case .history: HistoryScreen(model: model)
                        case .disk: DiskDiagnosticsScreen(model: model)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                }
            }
            .navigationTitle(model.page.title)
            .navigationSubtitle(model.selectedDiskName ?? "Backup Genius")
            .toolbar {
                if model.job != nil {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button(action: model.sync) { Label("立即同步", systemImage: "arrow.clockwise") }
                            .help("立即同步")
                            .disabled(!model.canSync)
                        Button(action: model.togglePause) {
                            Label(model.progress.state == .paused ? "继续" : "暂停",
                                  systemImage: model.progress.state == .paused ? "play" : "pause")
                        }
                        .help(model.progress.state == .paused ? "继续备份" : "暂停备份")
                        .disabled(!model.canPause)
                        Button(action: model.eject) { Label("安全推出", systemImage: "eject") }
                            .help("安全推出")
                            .disabled(!model.canEject)
                        Menu {
                            Button("在 Finder 中打开", action: model.openFolder).disabled(model.volume == nil || model.ejecting)
                            Button("完整校验", action: model.verify).disabled(!model.canSync)
                            if model.job?.format == .exfat {
                                Button("接管同步…") { model.setup = .takeover }
                                    .disabled(model.volume == nil || model.progress.state.busy || model.ejecting || model.restoring)
                            }
                            Divider()
                            Button("新手引导…") { model.setup = .guide }.disabled(model.busy)
                            Button("打开已有备份…") { model.setup = .existing }.disabled(model.busy)
                            if model.job?.setID == nil {
                                Button("更改备份…") { model.setup = .configure }
                                    .disabled(model.busy || model.restoring || model.ejecting)
                            } else if let mapping = model.selectedMapping {
                                Button(mapping.enabled ? "停用此备份" : "启用此备份") { model.setMappingEnabled(!mapping.enabled) }
                                    .disabled(model.busy || model.volume == nil || model.job?.restoreOnly == true)
                            }
                            SettingsLink { Text("设置…") }
                        } label: {
                            Label("更多备份操作", systemImage: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            let action = openWindow
            model.openBackupWindow = {
                action(id: "main")
                NSApp.activate()
            }
        }
        .onChange(of: model.page) { _, _ in model.loadRecords() }
        .sheet(item: $model.setup) { mode in
            switch mode {
            case .guide: BackupGuide(model: model)
            case .takeover: TakeoverView(model: model)
            case .configure, .existing: SetupView(model: model, mode: mode)
            }
        }
        .alert("需要处理", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("好", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private var showsFolderPicker: Bool { model.foldersOnSelectedDisk.count > 1 || model.job?.setID != nil }

    private var selectionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.disks.count > 1 {
                Picker("备份硬盘", selection: Binding(
                    get: { model.selectedDiskID }, set: { if let id = $0 { model.selectDisk(id) } }
                )) {
                    ForEach(model.disks) { disk in
                        Text(model.diskLabel(disk)).tag(Optional(disk.id))
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: 420, alignment: .leading)
                .help(model.selectedDisk.map { model.diskLabel($0) } ?? "选择备份硬盘")
            }
            if model.page == .overview {
                if showsFolderPicker {
                    HStack(spacing: 12) {
                        folderPicker
                        Spacer(minLength: 0)
                        addFolderButton
                    }
                } else {
                    addFolderButton.frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else if showsFolderPicker {
                folderPicker
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
    }

    private var addFolderButton: some View {
        Button("添加备份文件夹…", systemImage: "plus") { model.setup = .guide }
            .fixedSize(horizontal: true, vertical: false)
            .disabled(model.busy)
    }

    private var folderPicker: some View {
        Picker("所属文件夹", selection: Binding(
            get: { model.selectedFolder }, set: { if let id = $0 { model.selectFolder(id) } }
        )) {
            ForEach(model.foldersOnSelectedDisk) { folder in
                Text(folder.title).tag(Optional(folder.id))
            }
        }
        .lineLimit(1)
        .frame(maxWidth: 420, alignment: .leading)
        .help(model.folders.first(where: { $0.id == model.selectedFolder })?.title ?? "所属文件夹")
    }
}

private struct SidebarDisk: View {
    let name: String
    let volume: VolumeInfo?
    let state: SyncState
    let connected: Bool
    let configured: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(name)
                    Text(connectionStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: connected ? "externaldrive.fill" : "externaldrive")
                    .foregroundStyle(connected ? Color.accentColor : Color.secondary)
            }
            if let volume, volume.totalBytes > 0 {
                ProgressView(value: min(1, max(0, 1 - Double(volume.availableBytes) / Double(volume.totalBytes))))
                    .tint(.secondary)
                    .accessibilityLabel("已使用空间")
                Text("可用 \(byteCount(volume.availableBytes))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var connectionStatus: String {
        if let volume { return "\(volume.format.name) · 已连接" }
        if connected { return "已连接" }
        if state == .ejected { return "已推出" }
        if state == .ejecting { return "正在推出" }
        return configured ? "未连接" : "尚未选择"
    }
}

struct Overview: View {
    let model: AppModel

    var body: some View {
        if let job = model.job {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    status
                    if let prompt = model.selectedDiskPrompt {
                        VStack(alignment: .leading, spacing: 10) {
                            Label {
                                Text(prompt.volumeName).lineLimit(2).truncationMode(.middle)
                            } icon: {
                                Image(systemName: "externaldrive")
                            }
                            .font(.headline)
                            .help(prompt.volumeName)
                            ResponsiveActionRow {
                                Text("已连接，可备份 \(prompt.folderCount) 个文件夹").foregroundStyle(.secondary)
                            } actions: {
                                HStack(spacing: 8) {
                                    Button("稍后") { model.respondToBackupPrompt(prompt.id, backup: false) }
                                    Button("立即备份") { model.respondToBackupPrompt(prompt.id, backup: true) }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.secondary, in: .rect(cornerRadius: 12))
                    }
                    if job.setID != nil {
                        VStack(alignment: .leading, spacing: 11) {
                            ForEach(model.foldersOnSelectedDisk.filter { $0.job.setID == job.setID }) { folder in
                                Button { model.selectFolder(folder.id) } label: {
                                    HStack(spacing: 12) {
                                        Label {
                                            Text(folder.title).lineLimit(1).truncationMode(.middle)
                                        } icon: {
                                            Image(systemName: "folder")
                                        }
                                        Spacer(minLength: 0)
                                        Text(folder.mapping?.enabled == false ? "已停用" : folder.snapshot.progress.state.title)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: true, vertical: false)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(folder.title)
                            }
                        }
                    }
                    if model.progress.state == .takeoverRequired || (job.restoreOnly && job.format == .exfat && model.volume != nil) {
                        Button("预览接管…") { model.setup = .takeover }.buttonStyle(.borderedProminent)
                    }
                    if !job.restoreOnly {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(model.progress.sourceObservation ?? "准备记录文件变化", systemImage: "waveform.path")
                            Text(model.displayedProgress.state.busy ? "同步期间的新变化会继续记录，留待下一轮处理。" :
                                 (model.progress.sourceNeedsScan ? "事件记录需要补充核对；连接后自动处理。" :
                                  "已记录 \(model.progress.pendingSourcePaths.formatted()) 个待核对路径，硬盘断开时继续记录。"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    route(job)
                    if model.displayedProgress.elapsedSeconds > 0 || model.displayedProgress.state.busy {
                        metrics
                    } else {
                        Text("开始备份后显示本次进度与写入量。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if model.progress.unmanaged > 0 || model.progress.issueCount > 0 {
                        notices
                    }
                    Divider()
                    ResponsiveActionRow {
                        Label("保留旧版 \(BackupJob.retentionDays) 天", systemImage: "clock.arrow.circlepath")
                    } actions: {
                        Button("打开备份", systemImage: "folder", action: model.openFolder)
                            .disabled(model.volume == nil || model.progress.state.busy)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 850)
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        } else {
            ViewThatFits(in: .vertical) {
                empty
                ScrollView { empty }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var empty: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 24)
                    .fill(.tint.opacity(0.10))
                    .frame(width: 94, height: 94)
                    .overlay {
                        Image(systemName: "externaldrive.fill")
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(.tint)
                    }
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(9)
                    .background(.tint, in: .circle)
                    .padding(-3)
            }
            .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("连接硬盘，即可备份")
                    .font(.largeTitle.weight(.semibold))
                Text("选好外置硬盘和要备份的文件夹。再次连接已登记的硬盘时，Backup Genius 会提示你开始备份。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            HStack(spacing: 10) {
                Button("新手引导…") { model.setup = .guide }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("打开已有备份…") { model.setup = .existing }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            Label("支持 APFS 与 exFAT", systemImage: "externaldrive")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 5)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    private var status: some View {
        let progress = model.displayedProgress
        let state = progress.state
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: state.symbol)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(state.color)
                    .frame(width: 54, height: 54)
                    .background(state.color.opacity(0.12), in: .rect(cornerRadius: 15))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.ejecting ? "正在安全推出" : overviewTitle(state))
                        .font(.title2.weight(.semibold))
                    Text(statusDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .help(statusDetail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let running = model.folders.first(where: { $0.id == model.runningFolder }), running.id != model.selectedFolder,
               running.job.volumeID == model.job?.volumeID {
                Text("当前正在处理：\(running.title)")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(running.title)
            }
            if state.busy || model.ejecting {
                if let fraction = progress.fraction, !model.ejecting {
                    ProgressView(value: fraction) {
                        Text("\(progress.processed.formatted()) / \(progress.planned.formatted()) 项")
                            .font(.caption.monospacedDigit())
                    }
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .accessibilityLabel(state.title)
                }
                if state == .savingPoint && model.job?.format == .apfs {
                    Text("正在保存文件版本与目录信息").font(.callout).foregroundStyle(.secondary)
                } else if state == .savingPoint {
                    Text("归档写入 \(progress.writeBytesPerSecond.map { byteCount(Int64($0)) + "/s" } ?? "测量中") · 剩余时间估算中")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                if !model.ejecting && (state == .checking || state == .verifying || (state == .syncing && progress.planned > 0)) {
                    Text(state == .syncing ? backupTiming(progress) : "剩余时间估算中")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let path = progress.currentPath {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
            }
        }
        .padding(.top, 4)
    }

    private var statusDetail: String {
        let progress = model.displayedProgress
        if model.ejecting { return "正在等待当前更新完成并释放硬盘。" }
        if let message = progress.message { return message }
        switch progress.state {
        case .disconnected:
            if model.selectedDiskConnected {
                return model.selectedDiskPrompt != nil
                    ? "确认后将处理已记录的文件变化。" : "可立即备份或校验。"
            }
            return "连接 \(model.selectedDiskName ?? "备份硬盘") 以继续。"
        case .ready:
            return model.job?.restoreOnly == true ? "可浏览历史版本和恢复当前备份。" :
                (model.selectedDiskPrompt == nil && model.job?.automatic == true ? "正在等待备份。" : "可手动开始备份。")
        case .checking:
            return "已检查 \(progress.examined.formatted()) 项"
        case .verifying:
            return "正在比对文件内容与校验值。"
        case .syncing:
            return "\(max(0, progress.planned - progress.processed).formatted()) 项待处理"
        case .savingPoint: return "正在保存可独立恢复的文件版本。"
        case .recovering:
            return "正在恢复上次未提交的更新。"
        case .upToDate:
            if let last = progress.lastSuccess {
                return "最近检查 \(last.formatted(date: .abbreviated, time: .shortened))"
            }
            return "最新备份可用。"
        case .paused: return "随时可以继续检查和同步。"
        case .needsAttention: return "打开活动记录查看需要处理的项目。"
        case .takeoverRequired: return "先对齐本机文件夹与备份内容，再继续自动同步。"
        case .ejecting: return "正在安全卸载备份硬盘。"
        case .ejected: return "重新连接硬盘即可继续备份。"
        case .unconfigured: return "选择要备份的文件夹。"
        }
    }

    private func overviewTitle(_ state: SyncState) -> String {
        if model.selectedDiskPrompt != nil {
            return "等待确认备份"
        }
        return state == .disconnected && model.selectedDiskConnected ? "硬盘已连接" : state.title
    }

    private func route(_ job: BackupJob) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("所选文件夹的备份路径").font(.headline)
            let target = FolderTile(role: "目标文件夹", title: job.target.lastPathComponent,
                                    path: job.target.path, icon: "externaldrive.fill")
            if job.restoreOnly {
                target
            } else {
                let source = FolderTile(role: "源文件夹", title: job.source.lastPathComponent,
                                        path: job.source.path, icon: "folder.fill")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        source.frame(minWidth: 205, idealWidth: 205, maxWidth: .infinity)
                        routeArrow("arrow.right")
                        target.frame(minWidth: 205, idealWidth: 205, maxWidth: .infinity)
                    }
                    VStack(spacing: 8) {
                        source
                        routeArrow("arrow.down")
                        target
                    }
                }
            }
        }
    }

    private func routeArrow(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .accessibilityLabel("同步到")
    }

    private var metrics: some View {
        let progress = model.displayedProgress
        return VStack(alignment: .leading, spacing: 12) {
            Text("本次同步").font(.headline)
            let skipped = Metric(name: "已跳过", value: progress.skipped.formatted(), unit: "个未变化文件")
            let written = Metric(name: "最新副本写入", value: byteCount(progress.latestWrittenBytes), unit: "文件数据")
            let history = Metric(name: "历史数据写入", value: byteCount(progress.historyWrittenBytes), unit: "已归档的数据")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    skipped.fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity, alignment: .leading)
                    Divider().frame(height: 43)
                    written.fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity, alignment: .leading)
                    Divider().frame(height: 43)
                    history.fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 12) {
                    skipped
                    Divider().padding(.horizontal, 16)
                    written
                    Divider().padding(.horizontal, 16)
                    history
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
            .background(.background.secondary, in: .rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.separator) }
            if let reused = progress.reusedFiles, reused > 0 {
                Label("已沿用 \(reused.formatted()) 个一致的文件或链接", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.progress.issueCount > 0 {
                Label("\(model.progress.issueCount) 个项目需要处理", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
            if model.progress.unmanaged > 0 {
                Label("备份目录中有未纳入任务的文件，已保留", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }
}

private struct FolderTile: View {
    let role: String
    let title: String
    let path: String
    let icon: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(role).font(.caption).foregroundStyle(.secondary)
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(path).font(.caption).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.separator) }
        .help(path)
        .accessibilityElement(children: .combine)
    }
}

private struct Metric: View {
    let name: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.monospacedDigit().weight(.semibold))
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}

struct ResponsiveActionRow<Caption: View, Actions: View>: View {
    @ViewBuilder let caption: Caption
    @ViewBuilder let actions: Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                caption
                Spacer(minLength: 0)
                actions
            }
            VStack(alignment: .leading, spacing: 8) {
                caption
                actions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
