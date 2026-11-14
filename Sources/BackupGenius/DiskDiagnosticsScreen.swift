import SwiftUI
import BackupCore

struct DiskDiagnosticsScreen: View {
    let model: AppModel
    var body: some View {
        Form {
            Section("设备信息") {
                deviceValue("硬盘", model.volume?.name ?? model.job?.volumeName ?? "尚未选择")
                if let report = model.healthReport {
                    deviceValue("型号", report.model)
                    LabeledContent("连接方式", value: report.connection)
                    LabeledContent("介质", value: report.medium.name)
                    LabeledContent("健康报告") {
                        Text(report.health).foregroundStyle(report.warning ? .orange : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let temperature = report.temperature { LabeledContent("温度", value: "\(temperature) °C") }
                    if let used = report.percentageUsed { LabeledContent("厂家估算寿命已使用", value: "\(used)%") }
                    LabeledContent("记录方式") { Text(report.recording).fixedSize(horizontal: false, vertical: true) }
                    Text("读取时间：\(report.checked.formatted(date: .abbreviated, time: .standard))。健康报告无法预测所有故障。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("连接备份硬盘后，可读取设备提供的健康报告。部分 USB 硬盘盒不传递 S.M.A.R.T. 信息。")
                        .foregroundStyle(.secondary)
                }
                Button("读取健康信息") { model.diagnose(speed: false) }
                    .disabled(model.busy || model.diagnosing || !model.selectedDiskConnected)
            }
            Section("性能检测") {
                Text("使用 64 MiB 临时文件测量顺序读写与 4 KiB 随机读取延迟，结束后删除。检测期间暂停安排备份。短测会受到硬盘缓存影响，结果不代表长时间持续写入速度。")
                    .fixedSize(horizontal: false, vertical: true).foregroundStyle(.secondary)
                if let speed = model.speedReport {
                    LabeledContent("顺序读取", value: "\(byteCount(Int64(speed.readBytesPerSecond)))/s")
                    LabeledContent("顺序写入（含落盘）", value: "\(byteCount(Int64(speed.writeBytesPerSecond)))/s")
                    LabeledContent("随机读取延迟", value: String(format: "%.2f ms", speed.randomReadMilliseconds))
                    Text(speed.checked.formatted(date: .abbreviated, time: .standard)).font(.caption).foregroundStyle(.secondary)
                }
                if model.diagnosing { ProgressView("正在检测，请保持硬盘连接…") }
                Button("开始性能检测") { model.diagnose(speed: true) }
                    .disabled(model.busy || model.diagnosing || !model.selectedDiskConnected)
            }
            Section("备份优化") {
                Text("机械硬盘按目录顺序单路写入；SSD 在源和目标均适合时使用最多四路。识别不到类型时使用保守的单路策略。可在设置中修正介质类型。")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func deviceValue(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(value)
        }
    }
}

struct RestorePointsScreen: View {
    let model: AppModel
    @ViewState private var selection: UUID?
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("回到一次完整备份").font(.headline)
                Text("恢复所选文件夹在该时间点的全部内容，保存到新文件夹。保留最近 \(BackupJob.retentionDays) 天及最后一个时间点。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()
            if model.restorePoints.isEmpty {
                ContentUnavailableView("暂无可恢复的时间点", systemImage: "clock.arrow.circlepath",
                    description: Text("更新后完成一轮备份，即会建立第一个时间点。已有单文件旧版仍可在“历史版本”中恢复。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.restorePoints, selection: $selection) {
                    TableColumn("备份时间") { point in
                        Text(point.date.formatted(date: .abbreviated, time: .standard)).monospacedDigit()
                    }
                    .width(min: 165, ideal: 245)
                    TableColumn("文件数") { point in Text(point.files.formatted()).monospacedDigit() }
                        .width(min: 70, ideal: 100, max: 140)
                }
                .accessibilityLabel("可完整恢复的备份时间点")
                Divider()
                ResponsiveActionRow {
                    Text(model.restoring ? "正在恢复…" : "\(model.restorePoints.count.formatted()) 个时间点")
                        .foregroundStyle(.secondary).font(.caption)
                } actions: {
                    Button("恢复此时间点…") {
                        if let selection { model.restore(nil, point: selection) }
                    }
                    .disabled(selection == nil || !model.canRestore)
                }
                .padding(12)
            }
        }
        .onChange(of: model.restorePoints.map(\.id), initial: true) { _, ids in
            if selection == nil || !ids.contains(selection!) { selection = ids.first }
        }
    }
}
