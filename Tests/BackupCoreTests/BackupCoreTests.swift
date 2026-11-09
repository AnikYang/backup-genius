import Foundation
import Testing
import Darwin
@testable import BackupCore

private final class Fixture {
    let root: URL
    let source: URL
    let target: URL
    let restore: URL
    let state: URL
    let simulatedFormat: DiskFormat?

    init(_ format: DiskFormat = .apfs, liveEvents: Bool = false) throws {
        let token = "BackupGenius-test-\(UUID().uuidString)"
        let parent = liveEvents
            ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".build/event-tests")
            : FileManager.default.temporaryDirectory
        root = parent.appending(path: token)
        source = root.appending(path: "Source")
        restore = root.appending(path: "Restore")
        state = root.appending(path: "State")
        if let mount = ProcessInfo.processInfo.environment["BACKUP_GENIUS_TEST_\(format.rawValue.uppercased())"] {
            target = URL(fileURLWithPath: mount).appending(path: token)
            simulatedFormat = nil
        } else {
            target = root.appending(path: "Target")
            simulatedFormat = format == .exfat ? .exfat : nil
        }
        for url in [source, target, restore] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    func engine(watch: Bool = false, fault: (@Sendable (InterruptionPoint) throws -> Void)? = nil,
                storage: URL? = nil) -> SyncEngine {
        SyncEngine(storage: storage ?? state, allowInternal: true, monitor: watch, testFormat: simulatedFormat,
                   interruption: fault)
    }

    func write(_ name: String, _ data: Data, folder: URL? = nil) throws {
        let file = (folder ?? source).appending(path: name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    func read(_ name: String, folder: URL? = nil) throws -> Data {
        try Data(contentsOf: (folder ?? target).appending(path: name))
    }

    deinit {
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.removeItem(at: root)
    }
}

private func files(_ string: String) -> Data { Data(string.utf8) }
private func baseline(_ engine: SyncEngine, _ fixture: Fixture) async throws -> SyncProgress {
    _ = try await engine.configure(source: fixture.source, target: fixture.target, automatic: false)
    let result = try await engine.syncNow()
    try #require(result.state == .upToDate, "\(result.message ?? "")")
    return result
}

private func amend(_ old: Data, byte: UInt8, offset: Int) -> Data {
    var changed = old
    changed[offset] = byte
    return changed
}

private final class Tripwire: @unchecked Sendable {
    private let lock = NSLock()
    private var next: InterruptionPoint?
    func arm(_ point: InterruptionPoint) { lock.withLock { next = point } }
    func trigger(_ point: InterruptionPoint) throws {
        try lock.withLock {
            if point == next {
                next = nil
                throw BackupError.injected
            }
        }
    }
}

@Suite(.serialized)
struct BackupCoreTests {
    @Test("APFS copies new files, skips untouched data, and moves existing files without writing contents")
    func apfsIncremental() async throws {
        let fixture = try Fixture()
        let payload = Data(repeating: 12, count: blockSize * 4)
        try fixture.write("large.bin", payload)
        try fixture.write("folder/.hidden", files("tiny"))
        try fixture.write("remove.txt", files("old"))
        let engine = fixture.engine()
        let initial = try await baseline(engine, fixture)
        #expect(initial.latestWrittenBytes == Int64(payload.count + 7))
        let idle = try await engine.syncNow()
        #expect(idle.examined == 0)
        #expect(idle.sourceReadBytes == 0)
        #expect(idle.targetReadBytes == 0)
        #expect(idle.latestWrittenBytes == 0)
        #expect(try await engine.history().isEmpty)

        let changed = amend(payload, byte: 50, offset: blockSize + 13)
        let before = try #require(FileManager.default.attributesOfItem(atPath: fixture.source.appending(path: "large.bin").path)[.modificationDate])
        try fixture.write("large.bin", changed)
        try FileManager.default.setAttributes([.modificationDate: before], ofItemAtPath: fixture.source.appending(path: "large.bin").path)
        try FileManager.default.moveItem(at: fixture.source.appending(path: "folder/.hidden"),
                                         to: fixture.source.appending(path: "folder/moved.txt"))
        try FileManager.default.removeItem(at: fixture.source.appending(path: "remove.txt"))
        try await engine.simulate(source: Changes(paths: [
            "large.bin": flagModified, "folder/.hidden": flagRenamed, "folder/moved.txt": flagRenamed, "remove.txt": flagRemoved,
        ]))
        let result = try await engine.syncNow()
        #expect(result.state == .upToDate, "\(result.message ?? "")")
        #expect(result.latestWrittenBytes == blockSize)
        #expect(result.historyWrittenBytes == 0)
        #expect(try fixture.read("large.bin") == changed)
        #expect(try fixture.read("folder/moved.txt") == files("tiny"))
        #expect(!FileManager.default.fileExists(atPath: fixture.target.appending(path: "folder/.hidden").path))
        let activity = try await engine.activity()
        #expect(activity.contains { $0.kind == .moved && $0.path == "folder/moved.txt" })
        let versions = try await engine.history()
        #expect(versions.count == 2)
        let archived = try #require(versions.first { $0.path == "large.bin" })
        let restored = try await engine.restore(archived.id, to: fixture.restore)
        #expect(try fixture.read("large.bin", folder: restored) == payload)
    }

    @Test("exFAT rollback is durable across independent reopen", arguments: [
        InterruptionPoint.prepared, .firstBlock, .applied, .committed,
    ])
    func interruptedPatch(point: InterruptionPoint) async throws {
        let fixture = try Fixture(.exfat)
        let tripwire = Tripwire()
        let old = Data(repeating: 2, count: blockSize * 4)
        let new = amend(amend(old, byte: 8, offset: 21), byte: 9, offset: blockSize * 2 + 72)
        try fixture.write("document.bin", old)
        let engine = fixture.engine(fault: tripwire.trigger)
        _ = try await baseline(engine, fixture)
        try fixture.write("document.bin", new)
        try await engine.simulate(source: Changes(paths: ["document.bin": flagModified]))
        tripwire.arm(point)
        await #expect(throws: BackupError.self) { try await engine.syncNow() }
        if point == .firstBlock {
            #expect(try fixture.read("document.bin") == amend(old, byte: 8, offset: 21))
        }
        let restart = fixture.engine()
        try await restart.start()
        let prior = try fixture.read("document.bin")
        #expect(prior == (point == .committed ? new : old))
        let result = try await restart.syncNow()
        #expect(result.state == .upToDate, "\(result.message ?? "")")
        #expect(result.latestWrittenBytes == (point == .committed ? 0 : 2 * blockSize))
        #expect(try fixture.read("document.bin") == new)
        let versions = try await restart.history()
        let version = try #require(versions.first)
        let restored = try await restart.restore(version.id, to: fixture.restore)
        #expect(try fixture.read("document.bin", folder: restored) == old)
    }

    @Test("exFAT archive survives external edits and local index replacement")
    func portableHistory() async throws {
        let fixture = try Fixture(.exfat)
        let original = Data(repeating: 1, count: blockSize * 3)
        let updated = amend(original, byte: 2, offset: blockSize + 3)
        let external = amend(updated, byte: 3, offset: 7)
        try fixture.write("image.bin", original)
        try fixture.write(".data", files("dot"))
        let link = fixture.source.appending(path: "outside")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../Outside")
        var engine: SyncEngine? = fixture.engine()
        _ = try await baseline(engine!, fixture)
        try fixture.write("image.bin", updated)
        try await engine!.simulate(source: Changes(paths: ["image.bin": flagModified]))
        let first = try await engine!.syncNow()
        #expect(first.latestWrittenBytes == blockSize)
        #expect(try fixture.read("image.bin") == updated)
        try fixture.write("image.bin", external, folder: fixture.target)
        try fixture.write("Windows-note.txt", files("foreign"), folder: fixture.target)
        let verification = try await engine!.verify()
        #expect(verification.state == .upToDate, "\(verification.message ?? "")")
        #expect(verification.unmanaged >= 1)
        #expect(verification.latestWrittenBytes == blockSize)
        #expect(try fixture.read("Windows-note.txt") == files("foreign"))
        #expect(try fixture.read("image.bin") == updated)
        engine = nil

        let reinstalled = fixture.engine(storage: fixture.root.appending(path: "Reinstalled"))
        let config = try await reinstalled.openExisting(target: fixture.target)
        #expect(config.restoreOnly)
        let versions = try await reinstalled.history()
        try #require(versions.count == 2)
        let newer = try await reinstalled.restore(versions[0].id, to: fixture.restore)
        let older = try await reinstalled.restore(versions[1].id, to: fixture.restore)
        #expect(try fixture.read("image.bin", folder: newer) == external)
        #expect(try fixture.read("image.bin", folder: older) == original)
        let latest = try await reinstalled.restore(to: fixture.restore)
        #expect(try fixture.read(".data", folder: latest) == files("dot"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: latest.appending(path: "outside").path) == "../Outside")
    }

    @Test("Truncation and growth write changed blocks and retain old sizes")
    func truncateAndGrow() async throws {
        let fixture = try Fixture(.exfat)
        let old = Data(repeating: 4, count: 3 * blockSize)
        try fixture.write("blob", old)
        let engine = fixture.engine()
        _ = try await baseline(engine, fixture)

        let short = old.prefix(2 * blockSize)
        try fixture.write("blob", short)
        try await engine.simulate(source: Changes(paths: ["blob": flagModified]))
        let trim = try await engine.syncNow()
        #expect(trim.state == .upToDate)
        #expect(trim.latestWrittenBytes == 0)
        #expect(try fixture.read("blob") == short)
        let grown = short + Data(repeating: 5, count: blockSize + 87)
        try fixture.write("blob", grown)
        try await engine.simulate(source: Changes(paths: ["blob": flagModified]))
        let append = try await engine.syncNow()
        #expect(append.latestWrittenBytes == blockSize + 87)
        #expect(try fixture.read("blob") == grown)
        let history = try await engine.history()
        #expect(Set(history.map(\.size)) == Set([Int64(old.count), Int64(short.count)]))
    }

    @Test("Interrupted history cleanup preserves referenced blocks")
    func pruneAndRecover() async throws {
        let fixture = try Fixture(.exfat)
        let tripwire = Tripwire()
        let original = Data(repeating: 6, count: 3 * blockSize)
        let next = amend(original, byte: 7, offset: blockSize + 11)
        let third = amend(next, byte: 8, offset: blockSize * 2 + 10)
        try fixture.write("ledger", original)
        var engine: SyncEngine? = fixture.engine(fault: tripwire.trigger)
        _ = try await baseline(engine!, fixture)
        for contents in [next, third] {
            try fixture.write("ledger", contents)
            try await engine!.simulate(source: Changes(paths: ["ledger": flagModified]))
            #expect(try await engine!.syncNow().state == .upToDate)
        }
        let history = try await engine!.history()
        try #require(history.count == 2)
        let midpoint = history[1].date.addingTimeInterval(history[0].date.timeIntervalSince(history[1].date) / 2)
        tripwire.arm(.pruning)
        await #expect(throws: BackupError.self) {
            try await engine!.maintenance(now: midpoint.addingTimeInterval(30 * 86400))
        }
        engine = nil
        let reopened = fixture.engine()
        try await reopened.start()
        let surviving = try await reopened.history()
        #expect(surviving.map(\.id) == [history[0].id])
        let restored = try await reopened.restore(history[0].id, to: fixture.restore)
        #expect(try fixture.read("ledger", folder: restored) == next)
    }

    @Test("Unsafe paths, unsupported Windows names and unmanaged conflicts preserve existing data")
    func safety() async throws {
        let fixture = try Fixture(.exfat)
        try fixture.write("CON.txt", files("reserved"))
        try fixture.write("Photo.txt", files("new"))
        try fixture.write("photo.txt", files("existing"), folder: fixture.target)
        let engine = fixture.engine()
        await #expect(throws: BackupError.self) {
            try await engine.configure(source: fixture.root, target: fixture.target, automatic: false)
        }
        _ = try await engine.configure(source: fixture.source, target: fixture.target, automatic: false)
        let run = try await engine.syncNow()
        #expect(run.state == .needsAttention)
        #expect(run.issueCount == 2)
        #expect(try fixture.read("photo.txt") == files("existing"))
        #expect(!FileManager.default.fileExists(atPath: fixture.target.appending(path: "CON.txt").path))
        #expect(throws: BackupError.self) {
            let tree = try Tree(fixture.target.resolvingSymlinksInPath())
            _ = try tree.createFile("../escaped")
        }
    }

    @Test("Source loss does not delete latest backups")
    func sourceMissing() async throws {
        let fixture = try Fixture()
        try fixture.write("keep", files("valuable"))
        let engine = fixture.engine()
        _ = try await baseline(engine, fixture)
        try FileManager.default.removeItem(at: fixture.source)
        try await engine.simulate(source: Changes(fullScan: true))
        await #expect(throws: BackupError.self) { try await engine.syncNow() }
        #expect(try fixture.read("keep") == files("valuable"))
    }

    @Test("Native FSEvents queues changed files and resumes a persisted cursor")
    func liveEvents() async throws {
        let fixture = try Fixture(liveEvents: true)
        try fixture.write("changed.txt", files("original"))
        try fixture.write("skip.txt", Data(repeating: 0, count: blockSize * 2))
        var engine: SyncEngine? = fixture.engine(watch: true)
        _ = try await baseline(engine!, fixture)
        try fixture.write("changed.txt", files("changed!"))
        var changed = try await engine!.syncNow()
        for _ in 0..<12 where changed.sourceReadBytes == 0 {
            try await Task.sleep(for: .milliseconds(400))
            changed = try await engine!.syncNow()
        }
        #expect(changed.state == .upToDate, "\(changed.message ?? "")")
        #expect(changed.sourceReadBytes == 8)
        #expect(try fixture.read("changed.txt") == files("changed!"))
        let warm = try await engine!.syncNow()
        #expect(warm.sourceReadBytes == 0)
        #expect(warm.latestWrittenBytes == 0)
        engine = nil
        try fixture.write("changed.txt", files("offline!"))
        try await Task.sleep(for: .milliseconds(950))
        let restart = fixture.engine(watch: true)
        try await restart.start()
        let caughtUp = try await restart.syncNow()
        #expect(caughtUp.state == .upToDate, "\(caughtUp.message ?? "")")
        #expect(caughtUp.sourceReadBytes == 8)
        #expect(try fixture.read("changed.txt") == files("offline!"))
    }
}
