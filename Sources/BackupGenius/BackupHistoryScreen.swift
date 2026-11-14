import SwiftUI
import BackupCore

struct HistoryScreen: View {
    private enum Section: String, CaseIterable, Identifiable {
        case points = "时间点"
        case backups = "备份记录"
        case versions = "历史版本"
        var id: Self { self }
    }

    let model: AppModel
    @ViewState private var section = Section.points

    var body: some View {
        VStack(spacing: 0) {
            Picker("历史类型", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            .padding(10)
            Divider()
            Group {
                switch section {
                case .points: RestorePointsScreen(model: model)
                case .backups: BackupRunsScreen(model: model)
                case .versions: VersionHistoryScreen(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct BackupRunsScreen: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case added = "新增"
        case updated = "修改"

        var id: Self { self }
        var kind: Activity.Kind? {
            switch self {
            case .all: nil
            case .added: .added
            case .updated: .updated
            }
        }
    }

    private struct Request: Equatable {
        let run: UUID
        let changeCount: Int
        let kind: Activity.Kind?
        let query: String
        let page: Int
    }

    let model: AppModel
    private let pageSize = 200
    @ViewState private var selection: UUID?
    @ViewState private var filter = Filter.all
    @ViewState private var query = ""
    @ViewState private var page = 0
    @ViewState private var loaded: (Request, BackupRunChangePage)?

    private var request: Request? {
        guard let run = model.backupRuns.first(where: { $0.id == selection }) else { return nil }
        return Request(run: run.id, changeCount: run.added + run.updated, kind: filter.kind,
                       query: query.trimmingCharacters(in: .whitespacesAndNewlines), page: page)
    }

    private var visibleChanges: BackupRunChangePage? {
        guard let (completed, result) = loaded, completed == request else { return nil }
        return result
    }

    var body: some View {
        Group {
            if model.backupRuns.isEmpty {
                ContentUnavailableView("暂无备份记录", systemImage: "clock.arrow.circlepath",
                                       description: Text("完成一轮备份后，可在这里查看新增和修改的文件。"))
            } else {
                VStack(spacing: 0) {
                    VSplitView {
                        runsTable.frame(minHeight: 88, idealHeight: 140)
                        changesPane.frame(minHeight: 104)
                    }
                    .frame(maxHeight: .infinity)
                    if let request, let result = visibleChanges, !result.items.isEmpty {
                        Divider()
                        pagination(request, result)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.backupRuns.map(\.id), initial: true) { _, ids in
            if let selection, ids.contains(selection) { return }
            selection = ids.first
        }
        .onChange(of: selection) { _, _ in page = 0 }
        .onChange(of: filter) { _, _ in page = 0 }
        .onChange(of: query) { _, _ in page = 0 }
        .task(id: request) {
            guard let request else { loaded = nil; return }
            do {
                if !request.query.isEmpty { try await Task.sleep(for: .milliseconds(150)) }
                let result = try await model.engine.backupChanges(in: request.run, kind: request.kind,
                                                                  query: request.query, limit: pageSize,
                                                                  offset: request.page * pageSize)
                if !Task.isCancelled { loaded = (request, result) }
            } catch {
                if !Task.isCancelled { model.error = error.localizedDescription }
            }
        }
    }

    private var runsTable: some View {
        Table(model.backupRuns, selection: $selection) {
            TableColumn("备份时间") { run in
                Text(run.started.formatted(date: .abbreviated, time: .standard))
                    .monospacedDigit()
            }
            .width(min: 165, ideal: 207)
            TableColumn("结果") { run in
                switch run.outcome {
                case .completed: Label("已完成", systemImage: "checkmark.circle")
                case .needsAttention: Label("\(run.issueCount) 项待处理", systemImage: "exclamationmark.circle")
                case .interrupted: Label("中断", systemImage: "pause.circle")
                case .unconfirmed: Label("未记录完成", systemImage: "clock")
                }
            }
            .width(min: 100, ideal: 140)
            TableColumn("新增") { run in Text(run.added.formatted()).monospacedDigit() }
                .width(min: 55, ideal: 66)
            TableColumn("修改") { run in Text(run.updated.formatted()).monospacedDigit() }
                .width(min: 55, ideal: 66)
        }
        .accessibilityLabel("备份轮次")
    }

    private var changesPane: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    changeFilter
                    Spacer(minLength: 0)
                    changeSearch
                }
                VStack(alignment: .leading, spacing: 8) {
                    changeFilter
                    changeSearch
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            Divider()
            if let result = visibleChanges {
                if result.items.isEmpty {
                    Text(request?.changeCount == 0 ? "本轮无新增或修改" : "没有符合筛选的文件")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Table(result.items) {
                        TableColumn("类型") { item in Label(item.kind.title, systemImage: item.kind.symbol) }
                            .width(min: 75, ideal: 90, max: 120)
                        TableColumn("文件") { item in
                            Text(item.path).lineLimit(1).truncationMode(.middle).help(item.path)
                        }
                        .width(min: 96, ideal: 270)
                        TableColumn("写入") { item in
                            Text(byteCount(item.bytes)).monospacedDigit()
                        }
                        .width(min: 60, ideal: 82, max: 115)
                    }
                }
            } else {
                ProgressView("正在读取备份记录…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var changeFilter: some View {
        Picker("变化类型", selection: $filter) {
            ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private var changeSearch: some View {
        TextField("搜索文件名或路径", text: $query)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 155, maxWidth: 255)
    }

    private func pagination(_ request: Request, _ result: BackupRunChangePage) -> some View {
        let first = request.page * pageSize + 1
        let last = first + result.items.count - 1
        return ResponsiveActionRow {
            Text("\(first.formatted())–\(last.formatted()) / \(result.total.formatted()) 项")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } actions: {
            HStack(spacing: 8) {
                Button("上一页", systemImage: "chevron.left") { page -= 1 }.disabled(page == 0)
                Button("下一页", systemImage: "chevron.right") { page += 1 }.disabled(last >= result.total)
            }
        }
        .controlSize(.small)
        .padding(10)
    }
}
