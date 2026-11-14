import SwiftUI
import BackupCore

struct BackupGuide: View {
    @Environment(\.dismiss) private var dismiss
    let model: AppModel
    @ViewState private var step = 0
    @ViewState private var disk: URL?
    @ViewState private var volume: VolumeInfo?
    @ViewState private var sources: [URL] = []
    @ViewState private var preview: BackupSetupPreview?
    @ViewState private var groups: [UUID: String] = [:]
    @ViewState private var automatic = true
    @ViewState private var eject = true
    @ViewState private var login = false
    @ViewState private var working = false
    @ViewState private var error: String?

    private let titles = ["选择备份硬盘", "确认备份主目录", "选择要备份的文件夹", "预览备份映射"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(titles[step], systemImage: "externaldrive.badge.plus")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 22)
                .padding(.top, 22)
            Form {
                switch step {
                case 0:
                    Section("外置硬盘") {
                        if let volume {
                            LabeledContent(volume.name, value: "\(volume.format.name) · \(volume.device.medium.name)")
                            LabeledContent("可用空间", value: byteCount(volume.availableBytes))
                        }
                        Button("选择已连接的硬盘…", action: pickDisk)
                    }
                case 1:
                    Section("主目录") {
                        LabeledContent("文件夹名称", value: BackupSet.folderName)
                        if let disk {
                            let path = disk.appending(path: BackupSet.folderName).path
                            LabeledContent("位置") {
                                Text(path).lineLimit(2).truncationMode(.middle).help(path)
                            }
                        }
                        Text("开始备份时，Backup Genius 会创建或打开这个主目录。")
                            .foregroundStyle(.secondary)
                    }
                case 2:
                    Section("源文件夹") {
                        ForEach(sources, id: \.self) { source in
                            HStack {
                                Label {
                                    Text(source.path).lineLimit(2).truncationMode(.middle)
                                } icon: {
                                    Image(systemName: "folder")
                                }
                                .help(source.path)
                                Spacer(minLength: 0)
                                Button("移除", systemImage: "minus.circle") { sources.removeAll { $0 == source } }
                                    .labelStyle(.iconOnly)
                                    .fixedSize()
                                    .accessibilityLabel("移除 \(source.lastPathComponent)")
                            }
                        }
                        Button("添加文件夹…", systemImage: "plus", action: pickSources)
                    }
                default:
                    Section("源文件夹与备份位置") {
                        ForEach(preview?.rows ?? []) { row in
                            VStack(alignment: .leading, spacing: 5) {
                                let source = row.source?.path ?? row.name
                                Text(source).font(.subheadline)
                                    .lineLimit(2).truncationMode(.middle).help(source)
                                if !row.group.isEmpty {
                                    TextField("来源分组", text: Binding(
                                        get: { groups[row.id] ?? row.group },
                                        set: { groups[row.id] = $0 }
                                    ))
                                }
                                let group = groups[row.id] ?? row.group
                                let target = group.isEmpty ? row.name : "\(group)/\(row.name)"
                                Text("BackupGenius/\(target)").font(.callout).foregroundStyle(.secondary)
                                    .lineLimit(2).truncationMode(.middle).help("BackupGenius/\(target)")
                                if let previous = row.previousFolder, previous != target {
                                    Text("将已有备份从 \(previous) 移到此处")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Section("备份规则") {
                        Toggle("允许自动同步", isOn: $automatic)
                        Toggle("全部完成后自动推出硬盘", isOn: $eject)
                        Toggle("登录时启动", isOn: $login)
                        LabeledContent("旧版保留", value: "\(BackupJob.retentionDays) 天")
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .disabled(working)
            Divider()
            HStack {
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                if step > 0 { Button("上一步") { error = nil; step -= 1 }.disabled(working) }
                Button(step == 3 ? "开始备份" : "继续", action: advance)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(working || (step == 0 && disk == nil) || (step == 2 && sources.isEmpty))
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 17)
        }
        .frame(width: 660, height: 555)
        .interactiveDismissDisabled(working)
        .onAppear { login = model.loginEnabled }
        .onDisappear {
            if let preview { Task { await model.coordinator.discardSetup(preview.id) } }
        }
    }

    private func pickDisk() {
        Task {
            guard let chosen = await chooseFolder(title: "选择外置硬盘根目录", prompt: "选择",
                                                   startingAt: model.volume?.mount ?? URL(filePath: "/Volumes")) else { return }
            working = true
            defer { working = false }
            do {
                let info = try await Task.detached(priority: .utility) {
                    let access = chosen.startAccessingSecurityScopedResource()
                    defer { if access { chosen.stopAccessingSecurityScopedResource() } }
                    let info = try VolumeInfo.inspect(chosen)
                    guard info.isExternal, chosen.resolvingSymlinksInPath().path == info.mount.resolvingSymlinksInPath().path else {
                        throw BackupError.message("请选择外置硬盘的根目录")
                    }
                    return info
                }.value
                disk = chosen
                volume = info
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func pickSources() {
        Task {
            let chosen = await chooseFolders(title: "选择要备份的文件夹", prompt: "添加")
            for source in chosen where !sources.contains(source) { sources.append(source) }
            error = nil
        }
    }

    private func advance() {
        error = nil
        guard step >= 2 else { step += 1; return }
        guard let disk else { return }
        working = true
        Task {
            defer { working = false }
            do {
                if step == 2 {
                    preview = try await model.coordinator.previewSetup(volumeRoot: disk, sources: sources)
                    groups = [:]
                    step = 3
                } else if let preview {
                    let result = try await model.coordinator.confirmSetup(preview.id, groups: groups,
                                                                         automatic: automatic, ejectAfterBackup: eject)
                    let snapshot = await model.coordinator.presentation
                    model.folders = snapshot.folders
                    if let id = result.mappings.first(where: { mapping in
                        preview.rows.contains(where: { $0.id == mapping.id && $0.previousFolder == nil })
                    })?.job {
                        model.selectFolder(id)
                        if !automatic { Task { await model.coordinator.sync(id) } }
                    }
                    if login != model.loginEnabled { model.setLogin(login) }
                    model.page = .overview
                    dismiss()
                    await model.requestBackupNotificationPermission()
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
