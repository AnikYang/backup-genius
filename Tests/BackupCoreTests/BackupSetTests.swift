import Foundation
import Testing
@testable import BackupCore

private final class SetFixture {
    let root: URL
    let mount: URL
    let state: URL
    var jobs = Set<UUID>()

    init(_ format: DiskFormat) throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".build/set-tests/\(UUID())", directoryHint: .isDirectory)
        mount = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BACKUP_GENIUS_TEST_\(format.rawValue.uppercased())"]!)
        state = root.appending(path: "State")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func source(_ path: String, data: Data = Data("first".utf8)) throws -> URL {
        let source = root.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try data.write(to: source.appending(path: "payload.bin"))
        return source
    }

    func coordinator(monitor: Bool = false, _ eject: @escaping @Sendable (URL) throws -> DiskEjectAction = BackupDisk.prepare) -> BackupCoordinator {
        BackupCoordinator(storage: state, monitor: monitor, prepareEjection: eject)
    }

    func track(_ set: BackupSet) { jobs.formUnion(set.mappings.map(\.job)) }

    deinit {
        try? FileManager.default.removeItem(at: mount.appending(path: BackupSet.folderName))
        try? FileManager.default.removeItem(at: mount.appending(path: "\(storageName)/set"))
        for job in jobs { try? FileManager.default.removeItem(at: mount.appending(path: "\(storageName)/\(job.uuidString)")) }
        try? FileManager.default.removeItem(at: root)
    }
}

private actor SetEjection {
    private(set) var count = 0
    func completed() { count += 1 }
}

private final class SetFault: @unchecked Sendable {
    private let lock = NSLock()
    var point: SetInterruption?
    func trigger(_ point: SetInterruption) throws {
        try lock.withLock {
            if self.point == point { self.point = nil; throw BackupError.injected }
        }
    }
}

extension BackupCoreTests {
    @Test("Transfer timing uses actual writes and waits for a useful work sample")
    func transferTiming() {
        let meter = TransferProgress(total: 1000, at: 0)
        var progress = SyncProgress(state: .syncing)
        meter.beginBatch(500)
        meter.record(read: 100, written: 100)
        #expect(!meter.sample(at: 0.1, progress: &progress))
        #expect(meter.sample(at: 0.5, progress: &progress))
        #expect(progress.writeBytesPerSecond == 200)
        #expect(progress.estimatedSecondsRemaining == nil)
        meter.record(read: 100)
        #expect(meter.sample(at: 1.1, progress: &progress))
        #expect(progress.writeBytesPerSecond == 0)
        #expect(progress.estimatedSecondsRemaining != nil)
        #expect(meter.sample(at: 3.2, progress: &progress))
        #expect(progress.estimatedSecondsRemaining == nil)
        meter.finishBatch()
        meter.beginBatch(500)
        meter.finishBatch()
        #expect(meter.sample(at: 3.5, progress: &progress))
        #expect(progress.estimatedSecondsRemaining == nil)
    }

    @Test("A known disk needs a fresh choice before any automatic backup", .enabled(if: ProcessInfo.processInfo.environment["BACKUP_GENIUS_TEST_APFS"] != nil))
    func backupPromptOnConnection() async throws {
        let fixture = try SetFixture(.apfs)
        let first = try fixture.source("First")
        let second = try fixture.source("Second")
        let original = fixture.coordinator(monitor: true)
        try await original.start()
        let preview = try await original.previewSetup(volumeRoot: fixture.mount, sources: [first, second])
        let set = try await original.confirmSetup(preview.id, automatic: true, ejectAfterBackup: false)
        fixture.track(set)
        await original.sync(set.mappings[0].job)
        await original.finishAndClose()

        let current = fixture.coordinator(monitor: true)
        try await current.start()
        let prompt = try #require(await current.presentation.backupPrompts.first)
        #expect(prompt.folderCount == 2)
        #expect(await current.presentation.folders.allSatisfy { $0.snapshot.volume == nil })
        await current.volumesDidChange(mounted: fixture.mount)
        await current.volumesDidChange()
        #expect(await current.presentation.backupPrompts.map(\.id) == [prompt.id])
        await current.pause()
        await current.resume(set.mappings[0].job)
        #expect(await current.presentation.folders.allSatisfy { $0.snapshot.volume == nil })
        await current.respondToBackupPrompt(prompt.id, backup: false)
        await current.volumesDidChange(mounted: fixture.mount)
        await current.volumesDidChange()
        #expect(await current.presentation.backupPrompts.isEmpty)
        await current.respondToBackupPrompt(prompt.id, backup: true)
        let next = Data("updated".utf8)
        try next.write(to: first.appending(path: "payload.bin"))
        let copy = fixture.mount.appending(path: "BackupGenius/First/payload.bin")
        #expect(try Data(contentsOf: copy) == Data("first".utf8))
        let restoreFolder = fixture.root.appending(path: "Restore", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: restoreFolder, withIntermediateDirectories: true)
        let restored = try await current.restore(set.mappings[0].job, version: nil, to: restoreFolder)
        #expect(try Data(contentsOf: restored.appending(path: "payload.bin")) == Data("first".utf8))
        #expect(try Data(contentsOf: copy) == Data("first".utf8))

        await current.volumesDidChange(unmounted: fixture.mount)
        await current.volumesDidChange()
        let newPrompt = try #require(await current.presentation.backupPrompts.first)
        #expect(newPrompt.id != prompt.id)
        await current.respondToBackupPrompt(prompt.id, backup: true)
        #expect(await current.presentation.backupPrompts.map(\.id) == [newPrompt.id])
        await current.respondToBackupPrompt(newPrompt.id, backup: true)
        for _ in 0..<100 {
            if try Data(contentsOf: copy) == next,
               await current.presentation.diskProgress.values.contains(where: { $0.state == .upToDate }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try Data(contentsOf: copy) == next)
        #expect(await current.presentation.backupPrompts.isEmpty)
        await current.finishAndClose()
    }

    @Test("Mount discovery matches disk identity before opening a filesystem",
          .enabled(if: ProcessInfo.processInfo.environment["BACKUP_GENIUS_TEST_APFS"] != nil &&
                   ProcessInfo.processInfo.environment["BACKUP_GENIUS_TEST_EXFAT"] != nil))
    func mountedDriveLookup() throws {
        for format in [DiskFormat.apfs, .exfat] {
            let path = try #require(ProcessInfo.processInfo.environment["BACKUP_GENIUS_TEST_\(format.rawValue.uppercased())"])
            let volume = try VolumeInfo.inspect(URL(filePath: path))
            #expect(VolumeInfo.matchingMounts(volume.identifier, format: format).contains { $0.path == volume.mount.path })
            #expect(VolumeInfo.matchingMounts(UUID().uuidString, format: format).isEmpty)
        }
    }

    private func copySetFixture(_ source: URL, to target: URL) throws {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        for url in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey])
            where !url.lastPathComponent.hasPrefix("._") {
            let output = target.appending(path: url.lastPathComponent)
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                try copySetFixture(url, to: output)
            } else {
                try Data(contentsOf: url).write(to: output)
            }
        }
    }

    @Test("Export a Swift collection with incremental history for C++")
    func exportSetFixture() async throws {
        guard let output = ProcessInfo.processInfo.environment["BACKUP_GENIUS_EXPORT_SET_FIXTURE"],
              ProcessInfo.processInfo.environment["BACKUP_GENIUS_TEST_EXFAT"] != nil else { return }
        let fixture = try SetFixture(.exfat)
        var data = Data(repeating: 65, count: 2 * blockSize)
        let source = try fixture.source("Source", data: data)
        let coordinator = fixture.coordinator()
        try await coordinator.start()
        let preview = try await coordinator.previewSetup(volumeRoot: fixture.mount, sources: [source])
        let set = try await coordinator.confirmSetup(preview.id, automatic: false, ejectAfterBackup: false)
        fixture.track(set)
        let job = set.mappings[0].job
        await coordinator.sync(job)
        data[0] = 77
        try data.write(to: source.appending(path: "payload.bin"))
        let engine = try #require(await coordinator.engine(for: job))
        try await engine.simulate(source: Changes(paths: ["payload.bin": flagModified]))
        await coordinator.sync(job)
        #expect(engine.presentation.progress.latestWrittenBytes == blockSize)
        await coordinator.finishAndClose()
        let destination = URL(fileURLWithPath: output)
        try copySetFixture(fixture.mount.appending(path: BackupSet.folderName), to: destination.appending(path: BackupSet.folderName))
        try copySetFixture(fixture.mount.appending(path: "\(storageName)/\(job.uuidString)"),
                           to: destination.appending(path: "\(storageName)/\(job.uuidString)"))
    }

    @Test("Import a C++ collection, finish its interrupted move, restore and take over")
    func importSetFixture() async throws {
        guard let input = ProcessInfo.processInfo.environment["BACKUP_GENIUS_IMPORT_SET_FIXTURE"],
              ProcessInfo.processInfo.environment["BACKUP_GENIUS_TEST_EXFAT"] != nil else { return }
        let fixture = try SetFixture(.exfat)
        let source = URL(fileURLWithPath: input)
        for component in [BackupSet.folderName, storageName] {
            try copySetFixture(source.appending(path: component), to: fixture.mount.appending(path: component))
        }
        let saved = try BackupSetStore.read(Tree(fixture.mount), volume: VolumeInfo.inspect(fixture.mount))
        let set = try #require(saved)
        fixture.track(set)
        let coordinator = fixture.coordinator()
        try await coordinator.start()
        try await coordinator.openCollection(on: fixture.mount)
        let job = set.mappings[0].job
        let snapshot = await coordinator.presentation
        #expect(snapshot.folders.first(where: { $0.id == job })?.mapping?.folder == "Origin/Source")
        var expected = Data(repeating: 65, count: 2 * blockSize)
        expected[0] = 77
        expected[blockSize] = 87
        #expect(try Data(contentsOf: fixture.mount.appending(path: "BackupGenius/Origin/Source/payload.bin")) == expected)
        let output = fixture.root.appending(path: "Restored")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let engine = try #require(await coordinator.engine(for: job))
        let history = try await engine.history()
        #expect(history.count >= 2)
        let original = try #require(history.first(where: { $0.path == "payload.bin" }))
        let restored = try await coordinator.restore(job, version: original.id, to: output)
        #expect(try Data(contentsOf: restored.appending(path: "payload.bin"))[blockSize] == 65)
        let received = fixture.root.appending(path: "Received/Source")
        try FileManager.default.createDirectory(at: received, withIntermediateDirectories: true)
        let preview = try await engine.previewTakeover(source: received)
        _ = try await coordinator.confirmTakeover(job: job, preview: preview.id, choices: [:])
        #expect(try Data(contentsOf: received.appending(path: "payload.bin")) == expected)
        await coordinator.sync(job)
        #expect(engine.presentation.progress.state == .upToDate, "\(engine.presentation.progress.message ?? "")")
        await coordinator.finishAndClose()
    }

    @Test("Collection maps equal names, retains a legacy job, resumes after restart and follows a source rename",
          .enabled(if: ProcessInfo.processInfo.environment["BACKUP_GENIUS_TEST_APFS"] != nil))
    func collectionMapping() async throws {
        let fixture = try SetFixture(.apfs)
        let work = try fixture.source("Work/Projects")
        let personal = try fixture.source("Personal/Projects", data: Data("personal".utf8))
        let legacySource = try fixture.source("Legacy")
        let legacyTarget = fixture.mount.appending(path: "Legacy-\(UUID())")
        try FileManager.default.createDirectory(at: legacyTarget, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: legacyTarget) }
        let old = SyncEngine(storage: fixture.state, allowInternal: true, monitor: false)
        let legacyJob = try await old.configure(source: legacySource, target: legacyTarget, automatic: false)
        #expect(try await old.syncNow().state == .upToDate)
        await old.finishAndClose()

        let coordinator = fixture.coordinator()
        try await coordinator.start()
        let preview = try await coordinator.previewSetup(volumeRoot: fixture.mount, sources: [work, personal])
        #expect(preview.rows.map(\.folder) == ["Work/Projects", "Personal/Projects"])
        let set = try await coordinator.confirmSetup(preview.id, automatic: false, ejectAfterBackup: false)
        fixture.track(set)
        let first = set.mappings[0]
        await coordinator.sync(first.job)
        let target = fixture.mount.appending(path: BackupSet.target(first.folder))
        #expect(try Data(contentsOf: target.appending(path: "payload.bin")) == Data("first".utf8))
        #expect(await coordinator.presentation.folders.contains { $0.id == legacyJob.id && $0.job.target == legacyTarget })
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.mount.appending(path: BackupSet.folderName).path)
            .filter { isBackupControl($0) } == [identityName])
        let child = try Tree(target)
        #expect(try child.entry(identityName) == nil)
        let engine = try #require(await coordinator.engine(for: first.job))
        await coordinator.sync(first.job)
        let quiet = engine.presentation.progress
        #expect(quiet.state == .upToDate && quiet.sourceReadBytes == 0 && quiet.targetReadBytes == 0)
        #expect(quiet.latestWrittenBytes == 0 && quiet.historyWrittenBytes == 0 && quiet.sourceReadRequests == 0)

        let renamed = work.deletingLastPathComponent().appending(path: "Design")
        try FileManager.default.moveItem(at: work, to: renamed)
        await coordinator.sync(first.job)
        #expect(engine.presentation.progress.state == .upToDate, "\(engine.presentation.progress.message ?? "")")
        let renamedTarget = fixture.mount.appending(path: "BackupGenius/Work/Design")
        #expect(try Data(contentsOf: renamedTarget.appending(path: "payload.bin")) == Data("first".utf8))
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(engine.presentation.progress.latestWrittenBytes == 0)
        let lowercased = renamed.deletingLastPathComponent().appending(path: "design")
        try FileManager.default.moveItem(at: renamed, to: lowercased)
        await coordinator.sync(first.job)
        #expect(engine.presentation.progress.state == .upToDate, "\(engine.presentation.progress.message ?? "")")
        #expect(engine.presentation.job?.source.lastPathComponent == "design")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.mount.appending(path: "BackupGenius/Work").path)
            .contains("design"))
        #expect(engine.presentation.progress.latestWrittenBytes == 0)
        await coordinator.finishAndClose()

        let reopened = fixture.coordinator()
        try await reopened.start()
        #expect(await reopened.presentation.folders.count == 3)
        await reopened.sync(first.job)
        let restore = fixture.root.appending(path: "Restore")
        try FileManager.default.createDirectory(at: restore, withIntermediateDirectories: true)
        let restored = try await reopened.restore(first.job, version: nil, to: restore)
        #expect(try Data(contentsOf: restored.appending(path: "payload.bin")) == Data("first".utf8))
        await reopened.finishAndClose()
    }

    @Test("Adding a duplicate source groups an existing backup without copying its content",
          .enabled(if: ProcessInfo.processInfo.environment["BACKUP_GENIUS_TEST_EXFAT"] != nil))
    func collectionAddDuplicate() async throws {
        let fixture = try SetFixture(.exfat)
        let first = try fixture.source("Work/Projects")
        let second = try fixture.source("Personal/Projects")
        let coordinator = fixture.coordinator()
        try await coordinator.start()
        var preview = try await coordinator.previewSetup(volumeRoot: fixture.mount, sources: [first])
        let original = try await coordinator.confirmSetup(preview.id, automatic: false, ejectAfterBackup: false)
        fixture.track(original)
        await coordinator.sync(original.mappings[0].job)
        preview = try await coordinator.previewSetup(volumeRoot: fixture.mount, sources: [second])
        #expect(preview.rows.map(\.folder) == ["Work/Projects", "Personal/Projects"])
        let updated = try await coordinator.confirmSetup(preview.id, automatic: false, ejectAfterBackup: false)
        fixture.track(updated)
        #expect(updated.mappings[0].job == original.mappings[0].job)
        await coordinator.sync(updated.mappings[0].job)
        let engine = try #require(await coordinator.engine(for: updated.mappings[0].job))
        #expect(engine.presentation.progress.latestWrittenBytes == 0)
        #expect(try await engine.history().isEmpty)
        await coordinator.finishAndClose()
    }

    @Test("One missing source preserves its copy and lets the other mapping finish",
          .enabled(if: ProcessInfo.processInfo.environment["BACKUP_GENIUS_TEST_APFS"] != nil))
    func collectionPartialFailure() async throws {
        let fixture = try SetFixture(.apfs)
        let first = try fixture.source("First"), second = try fixture.source("Second")
        let coordinator = fixture.coordinator()
        try await coordinator.start()
        let preview = try await coordinator.previewSetup(volumeRoot: fixture.mount, sources: [first, second])
        let set = try await coordinator.confirmSetup(preview.id, automatic: false, ejectAfterBackup: false)
        fixture.track(set)
        await coordinator.sync(set.mappings[0].job)
        try FileManager.default.removeItem(at: first)
        try Data("updated".utf8).write(to: second.appending(path: "payload.bin"))
        let other = try #require(await coordinator.engine(for: set.mappings[1].job))
        try await other.simulate(source: Changes(paths: ["payload.bin": flagModified]))
        await coordinator.sync(set.mappings[0].job)
        let state = await coordinator.presentation
        #expect(state.folders.first(where: { $0.id == set.mappings[0].job })?.snapshot.progress.state == .needsAttention)
        #expect(other.presentation.progress.state == .upToDate)
        #expect(try Data(contentsOf: fixture.mount.appending(path: "BackupGenius/First/payload.bin")) == Data("first".utf8))
        #expect(try Data(contentsOf: fixture.mount.appending(path: "BackupGenius/Second/payload.bin")) == Data("updated".utf8))
        await coordinator.finishAndClose()
    }

    @Test("Collection eject waits for all mappings and I/O profiles bound the shared buffers",
          .enabled(if: ProcessInfo.processInfo.environment["BACKUP_GENIUS_TEST_EXFAT"] != nil))
    func collectionEjectAndProfile() async throws {
        for source in StorageMedium.allCases {
            for target in StorageMedium.allCases {
                let profile = IOProfile(source: source, target: target)
                #expect(profile.workers == (source == .ssd && target == .ssd ? 4 : 1))
                #expect(profile.bufferBudget <= IOProfile.bufferLimit)
            }
        }
        let fixture = try SetFixture(.exfat)
        let large = Data(repeating: 65, count: 5 * 1024 * 1024 + 123)
        let first = try fixture.source("First", data: large), second = try fixture.source("Second")
        let counter = SetEjection()
        let mount = fixture.mount
        let coordinator = fixture.coordinator { _ in
            return {
                guard FileManager.default.fileExists(atPath: mount.appending(path: "BackupGenius/First/payload.bin").path),
                      FileManager.default.fileExists(atPath: mount.appending(path: "BackupGenius/Second/payload.bin").path) else {
                    throw BackupError.message("A mapping was ejected before its data was published")
                }
                await counter.completed()
            }
        }
        try await coordinator.start()
        let preview = try await coordinator.previewSetup(volumeRoot: fixture.mount, sources: [first, second])
        let set = try await coordinator.confirmSetup(preview.id, automatic: false, ejectAfterBackup: true)
        fixture.track(set)
        await coordinator.sync(set.mappings[0].job)
        #expect(await counter.count == 1)
        let engine = try #require(await coordinator.engine(for: set.mappings[0].job))
        #expect(engine.presentation.progress.sourceReadRequests < large.count / blockSize)
        #expect(engine.presentation.progress.ioBufferBudget <= IOProfile.bufferLimit)
        #expect(try Data(contentsOf: fixture.mount.appending(path: "BackupGenius/First/payload.bin")) == large)
        await coordinator.finishAndClose()
    }

    @Test("Collection relocation recovery is repeatable after prepare, move and publication",
          .enabled(if: ProcessInfo.processInfo.environment["BACKUP_GENIUS_TEST_EXFAT"] != nil))
    func collectionInterruption() throws {
        for point in [SetInterruption.prepared, .relocated, .published] {
            let fixture = try SetFixture(.exfat)
            let volume = try VolumeInfo.inspect(fixture.mount)
            let fault = SetFault()
            let job = UUID()
            fixture.jobs.insert(job)
            var set = BackupSet(format: .exfat)
            set.revision = 1
            set.mappings = [FolderMapping(id: UUID(), job: job, folder: "Projects", enabled: true)]
            do {
                let store = try BackupSetStore(Scope(fixture.mount), volume: volume, interrupt: fault.trigger)
                let marker = Marker(version: 2, job: job, format: .exfat, initialWriter: UUID(), legacyGeneration: 0)
                try store.apply(SetTransition(base: 0, next: set, additions: [marker], moves: []))
                try Data("protected".utf8).write(to: fixture.mount.appending(path: "BackupGenius/Projects/payload"))
                set.revision = 2
                set.mappings[0].folder = "Work/Projects"
                fault.point = point
                #expect(throws: BackupError.self) {
                    try store.apply(SetTransition(base: 1, next: set, additions: [],
                        moves: [SetMove(from: "Projects", to: "Work/Projects", job: job)]))
                }
            }
            let reopened = try BackupSetStore(Scope(fixture.mount), volume: volume)
            #expect(try reopened.recover() == set)
            #expect(try reopened.recover() == set)
            #expect(try Data(contentsOf: fixture.mount.appending(path: "BackupGenius/Work/Projects/payload")) == Data("protected".utf8))
            #expect(try reopened.disk.entry("BackupGenius/Work/Projects/\(identityName)") == nil)
            #expect(try reopened.disk.entry(BackupSetStore.pending) == nil)
        }
    }
}
