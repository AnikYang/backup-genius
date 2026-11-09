import Foundation
import Darwin
import BackupCore

private struct Report: Codable {
    let operatingSystem: String
    let format: String
    let fileCount: Int
    let bytesPerFile: Int
    let edited: Int
    let moved: Int
    let cases: [String: SyncProgress]
}

private func successful(_ progress: SyncProgress) throws -> SyncProgress {
    guard progress.state == .upToDate else {
        throw BackupError.message(progress.message ?? progress.state.rawValue)
    }
    return progress
}

private func runBenchmark() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count <= 3 else {
        throw BackupError.message("用法：BackupBench [文件数] [目标卷测试目录] [JSON 报告路径]")
    }
    let count = arguments.first.flatMap(Int.init) ?? 100_000
    guard count >= 100, count <= 1_000_000 else { throw BackupError.message("文件数范围为 100 至 1,000,000") }
    let token = "BackupGenius-bench-\(UUID().uuidString)"
    let fixture = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: ".build/benchmark-fixtures").appending(path: token)
    let source = fixture.appending(path: "Source")
    let base = arguments.count >= 2 ? URL(fileURLWithPath: arguments[1]) : fixture
    let target = base.appending(path: token)
    let bytesPerFile = 1024
    let touched = count / 100

    for folder in [source, target] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    defer {
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.removeItem(at: fixture)
    }
    func path(_ i: Int) -> String { "\(i / 100)/\(i % 100).txt" }
    func payload(_ index: Int, edited: Bool = false) -> Data {
        var contents = Data(repeating: 101, count: bytesPerFile)
        contents.replaceSubrange(0..<8, with: withUnsafeBytes(of: UInt64(index).littleEndian) { Data($0) })
        if edited { contents[8] = 109 }
        return contents
    }
    for index in 0..<count {
        if index % 100 == 0 {
            try FileManager.default.createDirectory(at: source.appending(path: "\(index / 100)"),
                                                    withIntermediateDirectories: true)
        }
        try payload(index).write(to: source.appending(path: path(index)))
    }
    let largeSize = 32 * 1024 * 1024
    var largeFixture = Data(repeating: 0x7a, count: largeSize)
    for block in 0..<(largeSize / (64 * 1024)) {
        let offset = block * 64 * 1024
        largeFixture.replaceSubrange(offset..<(offset + 8),
                                     with: withUnsafeBytes(of: UInt64(block).littleEndian) { Data($0) })
    }
    try largeFixture.write(to: source.appending(path: "large.bin"))
    let engine = SyncEngine.testing(storage: fixture.appending(path: "State"), allowInternal: true)
    let job = try await engine.configure(source: source, target: target, automatic: false)
    var measurements: [String: SyncProgress] = [:]

    func record(_ name: String) async throws -> SyncProgress {
        let progress = try successful(await engine.syncNow())
        measurements[name] = progress
        FileHandle.standardError.write(Data("\(name): \(progress.elapsedSeconds.formatted(.number.precision(.fractionLength(3)))) s, \(progress.examined) metadata entries, \(progress.latestWrittenBytes) bytes\n".utf8))
        return progress
    }

    _ = try await record("initial")
    try await Task.sleep(for: .seconds(1))
    _ = try successful(await engine.syncNow())
    let noop = try await record("unchanged")
    guard noop.examined == 0, noop.sourceReadBytes == 0, noop.targetReadBytes == 0, noop.latestWrittenBytes == 0,
          noop.historyWrittenBytes == 0 else {
        throw BackupError.message("无变化同步未命中文件事件快路径")
    }

    for index in 0..<touched {
        try payload(index * 100, edited: true).write(to: source.appending(path: path(index * 100)))
    }
    try await Task.sleep(for: .seconds(1))
    let edit = try await record("editOnePercent")
    guard edit.latestWrittenBytes == Int64(touched * bytesPerFile) else {
        throw BackupError.message("小文件增量写入量与变化数量不符")
    }

    for index in 0..<touched {
        let from = source.appending(path: path(index * 100))
        try FileManager.default.moveItem(at: from, to: from.deletingPathExtension().appendingPathExtension("moved"))
    }
    try await Task.sleep(for: .seconds(1))
    let move = try await record("batchMove")
    guard move.latestWrittenBytes == 0 else { throw BackupError.message("批量移动复制了文件内容") }

    let large = try FileHandle(forUpdating: source.appending(path: "large.bin"))
    try large.seek(toOffset: 9 * 64 * 1024 + 9)
    try large.write(contentsOf: Data([0x9c]))
    try large.close()
    try await Task.sleep(for: .seconds(1))
    let patch = try await record("largeFileOneBlock")
    guard patch.latestWrittenBytes == 64 * 1024 else { throw BackupError.message("大文件变化超出一个块") }

    let report = Report(operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, format: job.format.name,
                        fileCount: count, bytesPerFile: bytesPerFile, edited: touched, moved: touched, cases: measurements)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let json = try encoder.encode(report)
    if arguments.count == 3 { try json.write(to: URL(fileURLWithPath: arguments[2]), options: .atomic) }
    FileHandle.standardOutput.write(json + Data([10]))
}

do {
    try await runBenchmark()
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
