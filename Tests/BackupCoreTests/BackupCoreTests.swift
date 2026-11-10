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

    init(_ format: DiskFormat = .apfs, liveEvents: Bool = false, useMountedVolume: Bool = true) throws {
        let token = "BackupGenius-test-\(UUID().uuidString)"
        let parent = liveEvents
            ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: ".build/event-tests")
            : FileManager.default.temporaryDirectory
        root = parent.appending(path: token)
        source = root.appending(path: "Source")
        restore = root.appending(path: "Restore")
        state = root.appending(path: "State")
        if useMountedVolume,
           let mount = ProcessInfo.processInfo.environment["BACKUP_GENIUS_TEST_\(format.rawValue.uppercased())"] {
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
    @Test("An unapplied exFAT patch recovers without writing to a read-only file")
    func readOnlyRecovery() async throws {
        let fixture = try Fixture(.exfat, useMountedVolume: false)
        let tripwire = Tripwire()
        let original = files("old")
        try fixture.write("protected.txt", original)
        let first = fixture.engine(fault: tripwire.trigger)
        _ = try await baseline(first, fixture)
        try fixture.write("protected.txt", files("new"))
        try await first.simulate(source: Changes(paths: ["protected.txt": flagModified]))
        tripwire.arm(.prepared)
        await #expect(throws: BackupError.self) { try await first.syncNow() }
        await first.finishAndClose()

        let target = try Tree(fixture.target.resolvingSymlinksInPath())
        let destination = fixture.target.appending(path: "protected.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: destination.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path) }
        #expect(throws: BackupError.self) { _ = try target.file("protected.txt", writable: true) }
        #expect(try target.entry("\(journalPath)/pending.json") != nil)

        let retry = fixture.engine()
        try await retry.start()
        #expect(try target.entry("\(journalPath)/pending.json") == nil)
        #expect(try fixture.read("protected.txt") == original)
        try fixture.write("other.txt", files("continue"))
        try await retry.simulate(source: Changes(paths: ["protected.txt": flagModified, "other.txt": flagCreated]))
        let result = try await retry.syncNow()
        #expect(result.issueCount == 1)
        #expect(try target.entry("\(journalPath)/pending.json") == nil)
        #expect(try fixture.read("protected.txt") == original)
        #expect(try fixture.read("other.txt") == files("continue"))
        await retry.finishAndClose()
    }

    @Test("Swift build caches stay outside scan and reconciliation, including previously backed-up caches")
    func excludesSwiftBuildCache() async throws {
        let fixture = try Fixture(.exfat)
        try fixture.write("Project/.build/old.bin", files("keep on disk"))
        try fixture.write("Notes/.build/.hidden", files("ordinary user file"))
        let engine = fixture.engine()
        _ = try await baseline(engine, fixture)
        try fixture.write("Project/Package.swift", files("// Swift package"))
        try FileManager.default.removeItem(at: fixture.source.appending(path: "Project/.build/old.bin"))
        try fixture.write("Project/.build/fixture/._data", files("cache sidecar"))
        try fixture.write("Project/report.txt", files("actual source data"))
        try fixture.write("Another/Package.swift", files("// Swift package"))
        try fixture.write("Another/.build", files("ordinary hidden file"))
        let result = try await engine.verify()
        #expect(result.state == .upToDate)
        #expect(try fixture.read("Project/.build/old.bin") == files("keep on disk"))
        #expect(!FileManager.default.fileExists(atPath: fixture.target.appending(path: "Project/.build/fixture/._data").path))
        #expect(try fixture.read("Notes/.build/.hidden") == files("ordinary user file"))
        #expect(try fixture.read("Another/.build") == files("ordinary hidden file"))
        #expect(try fixture.read("Project/report.txt") == files("actual source data"))

        try fixture.write("Project/.build/later", files("cache event"))
        try await engine.simulate(source: Changes(paths: ["Project/.build/later": flagCreated]))
        let idle = try await engine.syncNow()
        #expect(idle.examined == 0)
        #expect(idle.latestWrittenBytes == 0)
        await engine.finishAndClose()
    }

    @Test("Opt-in reuse verifies bytes and protects different files and shared directories")
    func reuseExistingMatchingFiles() async throws {
        let fixture = try Fixture(.exfat)
        try fixture.write("Manual/equal.txt", files("equal"))
        try fixture.write("Manual/conflict.txt", files("source"))
        try fixture.write("Manual/equal.txt", files("equal"), folder: fixture.target)
        try fixture.write("Manual/conflict.txt", files("target"), folder: fixture.target)
        try fixture.write("Manual/extra.txt", files("unrelated"), folder: fixture.target)
        for folder in [fixture.source, fixture.target] {
            try FileManager.default.createDirectory(at: folder.appending(path: "shared-empty"), withIntermediateDirectories: false)
        }
        let engine = fixture.engine()
        _ = try await engine.configure(source: fixture.source, target: fixture.target, automatic: false)
        let before = try await engine.syncNow()
        #expect(before.reusedFiles == nil)
        #expect(before.issueCount > 1)

        try await engine.setReuseMatchingFiles(true)
        let reused = try await engine.syncNow()
        #expect(reused.reusedFiles == 1)
        #expect(reused.issueCount == 1)
        #expect(reused.latestWrittenBytes == 0)
        #expect(try fixture.read("Manual/conflict.txt") == files("target"))
        #expect(try fixture.read("Manual/extra.txt") == files("unrelated"))
        await engine.finishAndClose()

        let reopened = fixture.engine()
        try await reopened.start()
        try fixture.write("Manual/equal.txt", files("updated"))
        try FileManager.default.removeItem(at: fixture.source.appending(path: "shared-empty"))
        try await reopened.simulate(source: Changes(paths: ["Manual/equal.txt": flagModified, "shared-empty": flagRemoved]))
        let updated = try await reopened.syncNow()
        #expect(updated.issueCount == 1)
        #expect(try fixture.read("Manual/equal.txt") == files("updated"))
        #expect(try await reopened.history().contains { $0.path == "Manual/equal.txt" })
        #expect(FileManager.default.fileExists(atPath: fixture.target.appending(path: "shared-empty").path))
        await reopened.finishAndClose()
    }

    @Test("Same-name files are compared by content and only changed blocks are written",
          arguments: [DiskFormat.apfs, .exfat])
    func updateExistingFiles(format: DiskFormat) async throws {
        let fixture = try Fixture(format)
        let original = Data(repeating: 15, count: 3 * blockSize)
        let changed = amend(original, byte: 90, offset: blockSize + 7)
        try fixture.write("Manual/changed.bin", changed)
        try fixture.write("Manual/changed.bin", original, folder: fixture.target)
        try fixture.write("Manual/equal.txt", files("same content"))
        try fixture.write("Manual/equal.txt", files("same content"), folder: fixture.target)
        try fixture.write("Manual/shortened.txt", Data())
        try fixture.write("Manual/shortened.txt", files("previous contents"), folder: fixture.target)
        try fixture.write("Manual/extra.txt", files("unrelated"), folder: fixture.target)

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for folder in [fixture.source, fixture.target] {
            let path = folder.appending(path: "Manual/changed.bin").path
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }
        let sameTarget = fixture.target.appending(path: "Manual/equal.txt")
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: sameTarget.path)
        let source = try Tree(fixture.source.resolvingSymlinksInPath())
        let target = try Tree(fixture.target.resolvingSymlinksInPath())
        #expect(try source.entry("Manual/changed.bin")?.modified == target.entry("Manual/changed.bin")?.modified)
        let equalBefore = try #require(try target.entry("Manual/equal.txt"))

        let engine = fixture.engine()
        _ = try await engine.configure(source: fixture.source, target: fixture.target, automatic: false)
        try await engine.setExistingFilesPolicy(.updateFromSource)
        let result = try await engine.syncNow()
        #expect(result.state == .upToDate, "\(result.message ?? "")")
        #expect(result.reusedFiles == 1)
        #expect(result.latestWrittenBytes == blockSize)
        #expect(result.unmanaged == 1)
        #expect(try target.entry("Manual/equal.txt") == equalBefore)
        #expect(try fixture.read("Manual/changed.bin") == changed)
        #expect(try fixture.read("Manual/shortened.txt").isEmpty)
        #expect(try fixture.read("Manual/extra.txt") == files("unrelated"))

        let history = try await engine.history()
        #expect(Set(history.map(\.path)) == ["Manual/changed.bin", "Manual/shortened.txt"])
        let archive = try #require(history.first { $0.path == "Manual/changed.bin" })
        let restored = try await engine.restore(archive.id, to: fixture.restore)
        #expect(try fixture.read("changed.bin", folder: restored) == original)
        await engine.finishAndClose()

        let reopened = fixture.engine()
        try await reopened.start()
        #expect(reopened.presentation.job?.existingFilesPolicy == .updateFromSource)
        let idle = try await reopened.syncNow()
        #expect(idle.sourceReadBytes == 0)
        #expect(idle.targetReadBytes == 0)
        #expect(idle.latestWrittenBytes == 0)
        #expect(try await reopened.history().count == 2)

        try fixture.write("Manual/later.txt", files("new"))
        try fixture.write("Manual/later.txt", files("old"), folder: fixture.target)
        try await reopened.simulate(source: Changes(paths: ["Manual/later.txt": flagCreated]))
        #expect(try await reopened.syncNow().state == .upToDate)
        #expect(try fixture.read("Manual/later.txt") == files("new"))
        await reopened.finishAndClose()
    }

    @Test("An interrupted first update restores the untracked disk copy")
    func recoverFirstExistingFileUpdate() async throws {
        let fixture = try Fixture(.exfat)
        let original = Data(repeating: 21, count: 2 * blockSize)
        let changed = amend(original, byte: 50, offset: 0)
        try fixture.write("existing.bin", original, folder: fixture.target)
        try fixture.write("existing.bin", changed)

        let tripwire = Tripwire()
        let engine = fixture.engine(fault: tripwire.trigger)
        _ = try await engine.configure(source: fixture.source, target: fixture.target, automatic: false,
                                       existingFiles: .updateFromSource)
        tripwire.arm(.firstBlock)
        await #expect(throws: BackupError.self) { try await engine.syncNow() }
        await engine.finishAndClose()

        let reopened = fixture.engine()
        try await reopened.start()
        #expect(try fixture.read("existing.bin") == original)
        #expect(try await reopened.history().isEmpty)
        #expect(try await reopened.syncNow().state == .upToDate)
        #expect(try fixture.read("existing.bin") == changed)
        let archive = try #require(try await reopened.history().first)
        let restored = try await reopened.restore(archive.id, to: fixture.restore)
        #expect(try fixture.read("existing.bin", folder: restored) == original)
        await reopened.finishAndClose()
    }

    @Test("Mac exFAT backup keeps the original names and adopts existing links without copying")
    func exfatMacNamesAndLinks() async throws {
        let fixture = try Fixture(.exfat)
        let directory = "Notes. "
        let document = "\(directory)/draft:review?.txt"
        let added = "\(directory)/CON.txt"
        let link = "\(directory)/pointer"
        let firstLink = files("../missing-original")
        let nextLink = files("../missing-replacement")
        try fixture.write(document, files("first"))
        try fixture.write(document, files("first"), folder: fixture.target)
        let source = try Tree(fixture.source.resolvingSymlinksInPath())
        let target = try Tree(fixture.target.resolvingSymlinksInPath())
        try source.createLink(firstLink, at: link)
        try target.createLink(firstLink, at: link)
        let originalLinkStamp = try #require(try target.entry(link))

        let fault = Tripwire()
        let engine = fixture.engine(fault: fault.trigger)
        _ = try await engine.configure(source: fixture.source, target: fixture.target, automatic: false,
                                       existingFiles: .updateFromSource)
        let initial = try await engine.syncNow()
        #expect(initial.state == .upToDate, "\(initial.message ?? "")")
        #expect(initial.reusedFiles == 2)
        #expect(initial.latestWrittenBytes == 0)
        #expect(try target.entry(link) == originalLinkStamp)
        #expect(try await engine.history().isEmpty)

        // Interrupt the first change to a physical link and verify the pending
        // transaction restores the exact link target on reopen.
        try source.remove(link)
        try source.createLink(nextLink, at: link)
        try await engine.simulate(source: Changes(paths: [link: flagModified]))
        fault.arm(.applied)
        await #expect(throws: BackupError.self) { try await engine.syncNow() }
        await engine.finishAndClose()

        let reopened = fixture.engine()
        try await reopened.start()
        #expect(try target.readLink(link) == firstLink)
        try fixture.write(document, files("revised"))
        try fixture.write(added, files("new file"))
        try await reopened.simulate(source: Changes(paths: [document: flagModified, added: flagCreated]))
        let changed = try await reopened.syncNow()
        #expect(changed.state == .upToDate, "\(changed.message ?? "")")
        #expect(try fixture.read(document) == files("revised"))
        #expect(try fixture.read(added) == files("new file"))
        #expect(try target.readLink(link) == nextLink)

        let restored = try await reopened.restore(to: fixture.restore)
        let output = try Tree(restored.resolvingSymlinksInPath())
        #expect(try fixture.read(document, folder: restored) == files("revised"))
        #expect(try output.readLink(link) == nextLink)
        let history = try await reopened.history()
        let savedLink = try #require(history.first { $0.path == link })
        let savedDocument = try #require(history.first { $0.path == document })
        let restoredLink = try await reopened.restore(savedLink.id, to: fixture.restore)
        let restoredDocument = try await reopened.restore(savedDocument.id, to: fixture.restore)
        #expect(try Tree(restoredLink.resolvingSymlinksInPath()).readLink("pointer") == firstLink)
        #expect(try fixture.read("draft:review?.txt", folder: restoredDocument) == files("first"))
        let verified = try await reopened.verify()
        #expect(verified.state == .upToDate, "\(verified.message ?? "")")
        #expect(verified.latestWrittenBytes == 0)
        await reopened.finishAndClose()
    }

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

    @Test("Unsafe paths and case conflicts preserve existing data")
    func safety() async throws {
        let fixture = try Fixture(.exfat)
        try fixture.write("Photo.txt", files("new"))
        try fixture.write("photo.txt", files("existing"), folder: fixture.target)
        let engine = fixture.engine()
        await #expect(throws: BackupError.self) {
            try await engine.configure(source: fixture.root, target: fixture.target, automatic: false)
        }
        _ = try await engine.configure(source: fixture.source, target: fixture.target, automatic: false,
                                       existingFiles: .updateFromSource)
        let run = try await engine.syncNow()
        #expect(run.state == .needsAttention)
        #expect(run.issueCount == 1)
        #expect(try fixture.read("photo.txt") == files("existing"))
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
