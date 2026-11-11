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
        case .syncing, .recovering: "arrow.triangle.2.circlepath"
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

struct MainWindow: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<Page?>(get: { model.page }, set: { model.page = $0 ?? .overview })) {
                Section("备份管理") {
                    ForEach(Page.allCases) { page in
                        Label(page.title, systemImage: page.symbol).tag(page)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 216, max: 260)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SidebarDisk(job: model.job, volume: model.volume, state: model.progress.state)
            }
        } detail: {
            Group {
                switch model.page {
                case .overview: Overview(model: model)
                case .activity: ActivityScreen(model: model)
                case .history: HistoryScreen(model: model)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if model.folders.count > 1 || model.job?.setID != nil {
                    HStack {
                        Picker("所属文件夹", selection: Binding(
                            get: { model.selectedFolder }, set: { if let id = $0 { model.selectFolder(id) } }
                        )) {
                            ForEach(model.folders) { folder in
                                Text(folder.title).tag(Optional(folder.id))
                            }
                        }
                        .frame(maxWidth: 420, alignment: .leading)
                        Spacer()
                        if model.page == .overview {
                            Button("添加备份文件夹…", systemImage: "plus") { model.setup = .guide }
                                .disabled(model.busy)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                    Divider()
                }
            }
            .navigationTitle(model.page.title)
            .navigationSubtitle(model.job.map { $0.restoreOnly ? "已有备份" : (model.volume?.name ?? $0.volumeName) } ?? "Backup Genius")
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
}

private struct SidebarDisk: View {
    let job: BackupJob?
    let volume: VolumeInfo?
    let state: SyncState

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(volume?.name ?? job?.volumeName ?? "备份硬盘")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(connectionStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: volume == nil ? "externaldrive" : "externaldrive.fill")
                    .foregroundStyle(volume == nil ? Color.secondary : Color.accentColor)
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
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private var connectionStatus: String {
        if let volume { return "\(volume.format.name) · 已连接" }
        if state == .ejected { return "已推出" }
        if state == .ejecting { return "正在推出" }
        return job == nil ? "尚未选择" : "未连接"
    }
}

struct Overview: View {
    let model: AppModel

    var body: some View {
        if let job = model.job {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    status
                    if job.setID != nil {
                        ForEach(model.folders.filter { $0.job.setID == job.setID }) { folder in
                            Button { model.selectFolder(folder.id) } label: {
                                HStack {
                                    Label(folder.title, systemImage: "folder")
                                    Spacer()
                                    Text(folder.mapping?.enabled == false ? "已停用" : folder.snapshot.progress.state.title)
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if model.progress.state == .takeoverRequired || (job.restoreOnly && job.format == .exfat && model.volume != nil) {
                        Button("预览接管…") { model.setup = .takeover }.buttonStyle(.borderedProminent)
                    }
                    route(job)
                    metrics
                    if model.progress.unmanaged > 0 || model.progress.issueCount > 0 {
                        notices
                    }
                    Divider()
                    HStack {
                        Label("保留旧版 \(BackupJob.retentionDays) 天", systemImage: "clock.arrow.circlepath")
                        Spacer()
                        Button("打开备份", systemImage: "folder", action: model.openFolder)
                            .disabled(model.volume == nil || model.progress.state.busy)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 850)
                .padding(30)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        } else {
            empty
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
                Text("选好外置硬盘和要备份的文件夹。下次连接时，Backup Genius 会检查变化并更新备份。")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var status: some View {
        let progress = model.displayedProgress
        let state = progress.state
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: state.symbol)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(state.color)
                    .frame(width: 54, height: 54)
                    .background(state.color.opacity(0.12), in: .rect(cornerRadius: 15))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.ejecting ? "正在安全推出" : state.title)
                        .font(.title2.weight(.semibold))
                    Text(statusDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
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
                if let path = progress.currentPath {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
            return "连接 \(model.job?.volumeName ?? "备份硬盘") 以继续。"
        case .ready:
            return model.job?.restoreOnly == true ? "可浏览历史版本和恢复当前备份。" :
                (model.job?.automatic == true ? "正在等待自动检查。" : "可从工具栏手动开始同步。")
        case .checking:
            return "已检查 \(progress.examined.formatted()) 项"
        case .verifying:
            return "正在比对文件内容与校验值。"
        case .syncing:
            return "\(max(0, progress.planned - progress.processed).formatted()) 项待处理"
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

    private func route(_ job: BackupJob) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("备份路径").font(.headline)
            HStack(spacing: 14) {
                FolderTile(role: "源文件夹", title: job.source.lastPathComponent, path: job.source.path, icon: "folder.fill")
                Image(systemName: "arrow.right")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("同步到")
                FolderTile(role: "目标文件夹", title: job.target.lastPathComponent,
                           path: job.target.path, icon: "externaldrive.fill")
            }
        }
    }

    private var metrics: some View {
        let progress = model.displayedProgress
        return VStack(alignment: .leading, spacing: 12) {
            Text("本次同步").font(.headline)
            HStack(spacing: 0) {
                Metric(name: "已跳过", value: progress.skipped.formatted(), unit: "个未变化文件")
                Divider().frame(height: 43)
                Metric(name: "最新副本写入", value: byteCount(progress.latestWrittenBytes), unit: "文件数据")
                Divider().frame(height: 43)
                Metric(name: "历史数据写入", value: byteCount(progress.historyWrittenBytes), unit: "已归档的数据")
            }
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
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(path).font(.caption).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
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
            Text(value).font(.title2.monospacedDigit().weight(.semibold)).lineLimit(1)
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
    }
}
