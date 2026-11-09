import Foundation
import Testing
@testable import BackupCore

@Suite(.serialized)
struct InteropTests {
    private func location(_ key: String) -> URL? {
        ProcessInfo.processInfo.environment[key].map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    // These fixtures contain only synthetic files and portable records. Copy the
    // bytes so exFAT's AppleDouble entries do not enter the cross-platform ZIP.
    private func copyFixture(_ source: URL, to target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: false)
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey])
            where !item.lastPathComponent.hasPrefix("._") {
            let output = target.appending(path: item.lastPathComponent)
            if try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                try copyFixture(item, to: output)
            } else {
                try Data(contentsOf: item).write(to: output)
            }
        }
    }

    @Test("Export a Swift-created exFAT v2 backup interrupted during a patch")
    func exportInteropFixture() async throws {
        guard let exported = location("BACKUP_GENIUS_EXPORT_FIXTURE") else { return }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "BG-Swift-\(UUID())")
        let targetParent = location("BACKUP_GENIUS_TEST_EXFAT") ?? root
        let target = targetParent.appending(path: "BG-Interop-\(UUID())")
        let source = root.appending(path: "Source")
        for folder in [source, target] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer {
            try? fm.removeItem(at: target)
            try? fm.removeItem(at: root)
        }
        let status = FixtureFault()
        let engine = SyncEngine(storage: root.appending(path: "State"), allowInternal: true, monitor: false,
                                testFormat: targetParent == root ? .exfat : nil, interruption: status.trigger)
        let file = source.appending(path: "payload.bin")
        var data = Data(repeating: 65, count: 2 * blockSize)
        try data.write(to: file)
        _ = try await engine.configure(source: source, target: target, automatic: false)
        #expect(try await engine.syncNow().state == .upToDate)
        data[0] = 77
        try data.write(to: file)
        try await engine.simulate(source: Changes(paths: ["payload.bin": flagModified]))
        #expect(try await engine.syncNow().latestWrittenBytes == blockSize)
        data[0] = 90
        try data.write(to: file)
        try await engine.simulate(source: Changes(paths: ["payload.bin": flagModified]))
        status.arm()
        await #expect(throws: BackupError.self) { try await engine.syncNow() }
        #expect(fm.fileExists(atPath: target.appending(path: "\(journalPath)/pending.json").path))
        await engine.finishAndClose()
        try copyFixture(target, to: exported)
    }

    @Test("Recover a C++ v2 transaction, restore its history and take over from Swift")
    func importInteropFixture() async throws {
        guard let imported = location("BACKUP_GENIUS_IMPORT_FIXTURE") else { return }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "BG-Swift-\(UUID())")
        let source = root.appending(path: "Source")
        let output = root.appending(path: "Restored")
        let parent = location("BACKUP_GENIUS_TEST_EXFAT") ?? root
        let target = parent.appending(path: "BG-Interop-\(UUID())")
        for folder in [source, output] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer {
            try? fm.removeItem(at: target)
            try? fm.removeItem(at: root)
        }
        try copyFixture(imported, to: target)
        let engine = SyncEngine(storage: root.appending(path: "State"), allowInternal: true, monitor: false,
                                testFormat: parent == root ? .exfat : nil)
        _ = try await engine.openExisting(target: target)
        var expected = Data(repeating: 65, count: 2 * blockSize)
        expected[0] = 77
        expected[blockSize] = 87
        #expect(try Data(contentsOf: target.appending(path: "payload.bin")) == expected)
        let archive = try #require(try await engine.history().first { $0.path == "payload.bin" })
        let restored = try await engine.restore(archive.id, to: output)
        #expect(try Data(contentsOf: restored.appending(path: "payload.bin"))[blockSize] == 65)
        let preview = try await engine.previewTakeover(source: source)
        _ = try await engine.confirmTakeover(preview.id, choices: [:])
        let file = source.appending(path: "payload.bin")
        #expect(try Data(contentsOf: file) == expected)
        #expect(fm.fileExists(atPath: source.appending(path: "windows.txt").path))
        expected[1] = 88
        try expected.write(to: file)
        try await engine.simulate(source: Changes(paths: ["payload.bin": flagModified]))
        #expect(try await engine.syncNow().state == .upToDate)
        #expect(try Data(contentsOf: target.appending(path: "payload.bin")) == expected)
        await engine.finishAndClose()
    }

    @Test("Upgrade a clean v1 journal without rewriting its commits or losing history")
    func upgradeLegacyJournal() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "BG-Legacy-\(UUID())")
        let source = root.appending(path: "Source")
        let target = (location("BACKUP_GENIUS_TEST_EXFAT") ?? root).appending(path: "BG-Legacy-\(UUID())")
        for folder in [source, target] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer {
            try? fm.removeItem(at: target)
            try? fm.removeItem(at: root)
        }
        let settings = root.appending(path: "Original")
        let testFormat: DiskFormat? = location("BACKUP_GENIUS_TEST_EXFAT") == nil ? .exfat : nil
        let first = SyncEngine(storage: settings, allowInternal: true, monitor: false, testFormat: testFormat)
        let file = source.appending(path: "file.txt")
        try Data("old".utf8).write(to: file)
        let job = try await first.configure(source: source, target: target, automatic: false)
        #expect(try await first.syncNow().state == .upToDate)
        try Data("new".utf8).write(to: file)
        try await first.simulate(source: Changes(paths: ["file.txt": flagModified]))
        #expect(try await first.syncNow().state == .upToDate)
        await first.finishAndClose()
        let disk = try Tree(target)
        let names = try disk.names(in: journalPath).filter {
            $0.count == 25 && $0.hasSuffix(".json") && Int64($0.prefix(20)) != nil
        }
        var prior: [String: Data] = [:]
        for name in names {
            let path = pathJoin(journalPath, name)
            var batch = try disk.readDocument(Envelope.self, from: path).batch()
            batch.version = nil
            batch.writer = nil
            try disk.writeDocument(try Envelope(batch), at: path, replacing: true)
            prior[path] = try Data(contentsOf: target.appending(path: path))
        }
        let marker = Marker(version: 1, job: job.id, volume: job.volumeID, format: .exfat,
                            sourceIdentity: job.sourceIdentity, sourcePath: source.path)
        try disk.writeDocument(marker, at: "\(controlName)/job.json", replacing: true)

        let upgraded = SyncEngine(storage: root.appending(path: "Upgrade"), allowInternal: true, monitor: false, testFormat: testFormat)
        _ = try await upgraded.openExisting(target: target)
        #expect(try await upgraded.history().count == 1)
        _ = try await upgraded.configure(source: source, target: target, automatic: false)
        let current = try disk.readDocument(Marker.self, from: "\(controlName)/job.json")
        #expect(current.version == 2)
        #expect(current.legacyGeneration == Int64(names.count))
        for (path, bytes) in prior { #expect(try Data(contentsOf: target.appending(path: path)) == bytes) }
        try Data("next".utf8).write(to: file)
        #expect(try await upgraded.syncNow().state == .upToDate)
        #expect(try await upgraded.history().count == 2)
        await upgraded.finishAndClose()
    }
}

private final class FixtureFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    func arm() { lock.withLock { armed = true } }
    func trigger(_ point: InterruptionPoint) throws {
        try lock.withLock {
            if armed && point == .firstBlock {
                armed = false
                throw BackupError.injected
            }
        }
    }
}
