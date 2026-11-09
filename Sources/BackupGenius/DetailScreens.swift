import SwiftUI
import AppKit
import ServiceManagement
import BackupCore

struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    let mode: SetupMode
    @ViewState private var source: URL?
    @ViewState private var target: URL?
    @ViewState private var volume: VolumeInfo?
    @ViewState private var automatic = true
    @ViewState private var login = false
    @ViewState private var pending = false
    @ViewState private var checkingDisk = false
    @ViewState private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(mode == .configure ? "设置备份" : "打开已有备份",
                  systemImage: mode == .configure ? "externaldrive.badge.plus" : "archivebox")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 21)
            Form {
                Section("文件夹") {
                    if mode == .configure {
                        folderRow("源文件夹", url: source) {
                            Task {
                                if let url = await chooseFolder(title: "选择源文件夹", prompt: "选择") {
                                    source = url
                                    failure = nil
                                }
                            }
                        }
                    }
                    folderRow("硬盘上的目标文件夹", url: target) {
                        Task {
                            if let url = await chooseFolder(title: "选择外置硬盘上的文件夹", prompt: "选择", canCreate: true) {
                                await inspect(url)
                            }
                        }
                    }
                    if checkingDisk {
                        ProgressView("正在检查硬盘…").controlSize(.small)
                    }
                    if let volume {
                        LabeledContent("硬盘") {
                            Text("\(volume.name) · \(volume.format.name) · 可用 \(byteCount(volume.availableBytes))")
                        }
                    }
                }
                if mode == .configure {
                    Section("规则") {
                        LabeledContent("同步方向", value: "Mac → 外置硬盘")
                        LabeledContent("旧版保留", value: "\(BackupJob.retentionDays) 天")
                        Toggle("连接后自动同步", isOn: $automatic)
                        Toggle("登录时启动", isOn: $login)
                    }
                    if volume?.format == .exfat {
                        Label("exFAT 备份可在 Windows 打开。同步中断时，正在更新的文件可能需要连接 Mac 恢复。",
                              systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            HStack {
                if pending { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(pending)
                Button(mode == .configure ? "保存任务" : "打开") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(target == nil || volume == nil || (mode == .configure && source == nil) || pending || checkingDisk)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 17)
        }
        .frame(width: 565, height: mode == .configure ? 470 : 310)
        .interactiveDismissDisabled(pending)
        .onAppear {
            if mode == .configure {
                source = model.job?.restoreOnly == false ? model.job?.source : nil
                if let job = model.job, model.volume != nil {
                    target = job.target
                    volume = model.volume
                    automatic = job.restoreOnly || job.automatic
                }
                login = model.loginEnabled
            }
        }
    }

    private func folderRow(_ title: String, url: URL?, choose: @escaping () -> Void) -> some View {
        HStack(spacing: 9) {
            Text(title)
            Spacer()
            if let url {
                Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle).help(url.path)
            } else {
                Text("未选择").foregroundStyle(.secondary)
            }
            Button(url == nil ? "选择…" : "更改…", action: choose)
                .accessibilityLabel("选择\(title)")
                .disabled(pending)
        }
        .accessibilityElement(children: .contain)
    }

    private func inspect(_ url: URL) async {
        checkingDisk = true
        defer { checkingDisk = false }
        target = url
        volume = nil
        failure = nil
        do {
            let result = try await Task.detached(priority: .utility) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                return try VolumeInfo.inspect(url)
            }.value
            guard result.isExternal else { throw BackupError.message("请选择外置硬盘上的文件夹") }
            volume = result
        } catch {
            failure = error.localizedDescription
        }
    }

    private func save() {
        guard let target else { return }
        pending = true
        failure = nil
        Task {
            defer { pending = false }
            do {
                switch mode {
                case .configure:
                    guard let source else { return }
                    model.job = try await model.engine.configure(source: source, target: target, automatic: automatic)
                    if login != model.loginEnabled { model.setLogin(login) }
                    model.page = .overview
                case .existing:
                    model.job = try await model.engine.openExisting(target: target)
                    model.page = .history
                    model.loadRecords()
                }
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

struct ActivityScreen: View {
    let model: AppModel
    @ViewState private var query = ""

    private var matching: [Activity] {
        if query.isEmpty { return model.activities }
        return model.activities.filter { $0.path.localizedStandardContains(query) ||
            $0.kind.title.localizedStandardContains(query) ||
            $0.detail?.localizedStandardContains(query) == true }
    }

    var body: some View {
        Group {
            if model.activities.isEmpty {
                ContentUnavailableView("暂无活动记录", systemImage: "list.bullet.rectangle",
                                       description: Text("每次备份的变化和需要处理的项目会显示在这里。"))
            } else if matching.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                Table(matching) {
                    TableColumn("操作") { item in
                        Label(item.kind.title, systemImage: item.kind.symbol)
                            .foregroundStyle(item.kind == .issue ? Color.orange : Color.primary)
                    }
                    .width(min: 88, ideal: 100)
                    TableColumn("文件") { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.path).lineLimit(1).truncationMode(.middle)
                            if let detail = item.detail {
                                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .help(item.detail ?? item.path)
                    }
                    TableColumn("时间") { item in
                        Text(item.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    }
                    .width(min: 100, ideal: 132)
                    TableColumn("写入") { item in
                        Text(item.bytes == 0 ? "—" : byteCount(item.bytes)).monospacedDigit()
                    }
                    .width(min: 65, ideal: 80)
                }
            }
        }
        .searchable(text: $query, prompt: "搜索活动")
    }
}

struct HistoryScreen: View {
    let model: AppModel
    @ViewState private var query = ""
    @ViewState private var selection: UUID?

    private var matching: [HistoryItem] {
        if query.isEmpty { return model.versions }
        return model.versions.filter { $0.path.localizedStandardContains(query) ||
            $0.date.formatted(date: .abbreviated, time: .omitted).localizedStandardContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if model.versions.isEmpty {
                    ContentUnavailableView("暂无历史版本", systemImage: "clock.arrow.circlepath",
                                           description: Text("替换或删除的旧文件会在硬盘上保留 \(BackupJob.retentionDays) 天。"))
                        .frame(maxHeight: .infinity)
                } else if matching.isEmpty {
                    ContentUnavailableView.search(text: query).frame(maxHeight: .infinity)
                } else {
                    Table(matching, selection: $selection) {
                        TableColumn("文件") { item in
                            Label(item.path, systemImage: "doc")
                                .lineLimit(1).truncationMode(.middle)
                                .help(item.path)
                        }
                        TableColumn("版本日期") { item in
                            Text(item.date.formatted(date: .abbreviated, time: .shortened))
                        }
                        .width(min: 100, ideal: 142)
                        TableColumn("来源") { item in Text(item.reason.title) }.width(min: 65, ideal: 80)
                        TableColumn("大小") { item in Text(byteCount(item.size)).monospacedDigit() }
                            .width(min: 65, ideal: 85)
                    }
                    .contextMenu(forSelectionType: UUID.self) { ids in
                        if let id = ids.first {
                            Button("恢复此版本…") { model.restore(id) }.disabled(!model.canRestore)
                        }
                    } primaryAction: { ids in
                        if let id = ids.first { model.restore(id) }
                    }
                }
            }
            Divider()
            HStack {
                if model.restoring {
                    ProgressView().controlSize(.small)
                    Text("正在恢复…").foregroundStyle(.secondary)
                } else {
                    Text("\(matching.count.formatted()) 个版本").foregroundStyle(.secondary)
                }
                Spacer()
                Button("恢复当前备份…") { model.restore(nil) }
                    .disabled(!model.canRestore || model.progress.trackedFiles == 0)
                Button("恢复所选版本…") { model.restore(selection) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canRestore || !matching.contains(where: { $0.id == selection }))
            }
            .padding(12)
        }
        .searchable(text: $query, prompt: "搜索文件或日期")
    }
}

struct AppSettings: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section("启动") {
                Toggle("登录时启动 Backup Genius", isOn: Binding(
                    get: { model.loginEnabled }, set: { model.setLogin($0) }
                ))
                if model.loginNeedsApproval {
                    Button("在系统设置中批准") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            Section("备份") {
                if let job = model.job {
                    Toggle("连接硬盘后自动同步", isOn: Binding(
                        get: { model.job?.automatic ?? false }, set: { model.setAutomatic($0) }
                    ))
                    .disabled(job.restoreOnly)
                    LabeledContent("历史保留", value: "\(BackupJob.retentionDays) 天")
                }
                Button("设置备份…") {
                    openWindow(id: "main")
                    model.setup = .configure
                }
                .disabled(model.progress.state.busy || model.restoring || model.ejecting)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 270)
        .onAppear { model.refreshLoginStatus() }
    }
}
