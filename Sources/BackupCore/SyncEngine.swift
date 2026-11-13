import Foundation
import Darwin

public struct BackupPresentation: Sendable {
    public let job: BackupJob?
    public let volume: VolumeInfo?
    public let progress: SyncProgress
    public let organizedStorage: Bool
    public let sourceDevice: StorageDeviceInfo?
}

private struct Subscribers {
    var latest = BackupPresentation(job: nil, volume: nil, progress: SyncProgress(), organizedStorage: false, sourceDevice: nil)
    var streams: [UUID: AsyncStream<SyncProgress>.Continuation] = [:]
}

final class Scope: @unchecked Sendable {
    let url: URL
    private let accessed: Bool

    init(_ url: URL) {
        self.url = url
        accessed = url.startAccessingSecurityScopedResource()
    }

    deinit { if accessed { url.stopAccessingSecurityScopedResource() } }

    static func resolving(_ bookmark: Data?, fallback: URL) -> Scope {
        if let bookmark {
            var stale = false
            for options: URL.BookmarkResolutionOptions in [[.withSecurityScope, .withoutUI, .withoutMounting], [.withoutUI, .withoutMounting]] {
                if let url = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil,
                                      bookmarkDataIsStale: &stale) { return Scope(url) }
            }
        }
        return Scope(fallback)
    }
}

private final class PreparationResults: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Result<Prepared, Error>?]

    init(count: Int) { entries = Array(repeating: nil, count: count) }
    func set(_ item: Result<Prepared, Error>, at index: Int) { lock.withLock { entries[index] = item } }
    func result() -> [Result<Prepared, Error>] { lock.withLock { entries.map { $0! } } }
}

/// The serial utility queue owns the database, drive lease and transaction
/// writer. Independent preparation workers use descriptor-relative I/O only.
public final class SyncEngine: @unchecked Sendable {
    private let queue: DispatchQueue
    private let publishedLock = NSLock()
    private var subscribers = Subscribers()
    private let pauseLock = NSLock()
    private var pauseRequested = false

    private let storage: URL
    private let allowInternal: Bool
    private let monitor: Bool
    private let testFormat: DiskFormat?
    private let interruption: (@Sendable (InterruptionPoint) throws -> Void)?
    private let prepareEjection: @Sendable (URL) throws -> DiskEjectAction
    private var started = false
    private var job: BackupJob?
    private var catalog: Catalog?
    private var repository: Repository?
    private var scratch: Tree?
    private var sourceScope: Scope?
    private var targetScope: Scope?
    private var storageScope: Scope?
    private var sourceMonitor: EventMonitor?
    private var targetMonitor: EventMonitor?
    private var streamFailure = false
    private var scheduled: DispatchWorkItem?
    private var forceAutomatic = false
    private var automaticRetries = 0
    private var unstableThisRun = false
    private var timer: DispatchSourceTimer?
    private var suppressConnection = false
    private var ejectionTask: Task<Void, Never>?
    private var volumeChangedWhileEjecting = false
    private var progress = SyncProgress()
    private var lastPublished: Double = 0
    private let transferQueue = DispatchQueue(label: "backupgenius.progress", qos: .utility)
    private var transferTimer: DispatchSourceTimer?
    private var host = UUID()
    private let sharedHost: UUID?
    private var automaticHandler: (@Sendable (Bool) -> Void)?
    private var mappedVolume: VolumeInfo?
    private var sourceDevice: (dev_t, StorageDeviceInfo)?
    private var mediumOverrides: [String: StorageMedium] = [:]
    private var takeover: (draft: TakeoverDraft, job: BackupJob, access: Scope)?

    public convenience init(storage: URL) {
        self.init(storage: storage, allowInternal: false, monitor: true)
    }

    public static func testing(storage: URL, allowInternal: Bool) -> SyncEngine {
        SyncEngine(storage: storage, allowInternal: allowInternal, monitor: true)
    }

    init(storage: URL, allowInternal: Bool, monitor: Bool, testFormat: DiskFormat? = nil,
         interruption: (@Sendable (InterruptionPoint) throws -> Void)? = nil,
         prepareEjection: @escaping @Sendable (URL) throws -> DiskEjectAction = BackupDisk.prepare,
         queue: DispatchQueue = DispatchQueue(label: "backupgenius.engine", qos: .utility),
         host: UUID? = nil, automaticHandler: (@Sendable (Bool) -> Void)? = nil) {
        self.storage = storage
        self.allowInternal = allowInternal
        self.monitor = monitor
        self.testFormat = testFormat
        self.interruption = interruption
        self.prepareEjection = prepareEjection
        self.queue = queue
        sharedHost = host
        self.automaticHandler = automaticHandler
    }

    public var presentation: BackupPresentation {
        publishedLock.withLock { subscribers.latest }
    }

    public func updates() -> AsyncStream<SyncProgress> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            publishedLock.withLock {
                subscribers.streams[id] = continuation
                continuation.yield(subscribers.latest.progress)
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.publishedLock.withLock { self.subscribers.streams.removeValue(forKey: id) }
            }
        }
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable (SyncEngine) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body(self) })
            }
        }
    }

    private var isPaused: Bool { pauseLock.withLock { pauseRequested } }
    private func setPaused(_ paused: Bool) { pauseLock.withLock { pauseRequested = paused } }

    private func publish(force: Bool = true) {
        let now = ProcessInfo.processInfo.systemUptime
        publishedLock.withLock {
            guard force || now - lastPublished >= 0.2 else { return }
            var current = progress
            if current.state == .syncing, subscribers.latest.progress.state == .syncing {
                current.writeBytesPerSecond = subscribers.latest.progress.writeBytesPerSecond
                current.estimatedSecondsRemaining = subscribers.latest.progress.estimatedSecondsRemaining
            }
            let snapshot = BackupPresentation(job: job, volume: repository?.volume, progress: current,
                                              organizedStorage: repository?.tree.controlTree != nil, sourceDevice: sourceDevice?.1)
            lastPublished = now
            subscribers.latest = snapshot
            for stream in subscribers.streams.values { stream.yield(current) }
        }
    }

    private func startTransferProgress(_ meter: TransferProgress) {
        let timer = DispatchSource.makeTimerSource(queue: transferQueue)
        timer.schedule(deadline: .now() + .milliseconds(400), repeating: .milliseconds(400), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.sampleTransferProgress(meter) }
        transferTimer = timer
        timer.resume()
    }

    private func sampleTransferProgress(_ meter: TransferProgress) {
        publishedLock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            let old = subscribers.latest
            var current = old.progress
            guard current.state == .syncing, now - lastPublished >= 0.2,
                  meter.sample(at: now, progress: &current) else { return }
            lastPublished = now
            subscribers.latest = BackupPresentation(job: old.job, volume: old.volume, progress: current,
                                                      organizedStorage: old.organizedStorage, sourceDevice: old.sourceDevice)
            for stream in subscribers.streams.values { stream.yield(current) }
        }
    }

    private var configURL: URL { storage.appending(path: "job.json") }

    public func start(connect: Bool = true) async throws {
        try await perform { engine in
            do {
                try engine.load()
                if connect {
                    try engine.refresh()
                    engine.schedule(force: true)
                }
            } catch {
                engine.fail(error)
                throw error
            }
        }
    }

    private func load() throws {
        guard !started else { return }
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let hostURL = storage.appending(path: "host-id")
        host = try sharedHost ?? Self.hostID(at: hostURL)
        let scratchURL = storage.appending(path: "scratch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: true)
        scratch = try Tree(scratchURL.resolvingSymlinksInPath())
        if FileManager.default.fileExists(atPath: configURL.path) {
            let loaded = try JSONDecoder().decode(BackupJob.self, from: Data(contentsOf: configURL))
            try setJob(loaded)
        }
        started = true
    }

    static func hostID(at url: URL) throws -> UUID {
        if FileManager.default.fileExists(atPath: url.path) {
            guard let saved = UUID(uuidString: try String(contentsOf: url, encoding: .utf8)) else {
                throw BackupError.message("本机备份标识无效")
            }
            return saved
        }
        let id = UUID()
        try id.uuidString.write(to: url, atomically: true, encoding: .utf8)
        return id
    }

    func coordinate(_ handler: @escaping @Sendable (Bool) -> Void) async throws {
        try await perform { $0.automaticHandler = handler }
    }

    private func periodic() {
        guard let job, let repository, !isPaused else { return }
        do {
            guard try !requiresTakeover(repository, job: job), !job.restoreOnly || !repository.descriptor.portable else { return }
            let due = try verifyDue(repository.catalog)
            if !job.restoreOnly, job.automatic, due || streamFailure {
                if let automaticHandler { automaticHandler(due) }
                else { _ = try run(verify: due) }
            } else {
                try pruneIfDue(repository)
            }
        } catch { fail(error) }
    }

    private func startMaintenance() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(60), repeating: .seconds(60), leeway: .seconds(10))
        timer.setEventHandler { [weak self] in self?.periodic() }
        self.timer = timer
        timer.resume()
    }

    private func stopMaintenance() {
        timer?.cancel()
        timer = nil
    }

    public func configure(source: URL, target: URL, automatic: Bool = true, reuseMatchingFiles: Bool = false) async throws -> BackupJob {
        try await configure(source: source, target: target, automatic: automatic,
                            existingFiles: reuseMatchingFiles ? .reuseIdentical : .preserve)
    }

    public func configure(source: URL, target: URL, automatic: Bool = true,
                          existingFiles: ExistingFilesPolicy, ejectAfterBackup: Bool = false,
                          volumeRoot: URL? = nil) async throws -> BackupJob {
        try await perform { engine in
            try engine.load()
            guard engine.ejectionTask == nil else { throw BackupError.message("正在推出硬盘，请稍候") }
            let sourceAccess = Scope(source)
            let targetAccess = Scope(target)
            let selectedStorage = volumeRoot.map(Scope.init)
            return try withExtendedLifetime((sourceAccess, targetAccess, selectedStorage)) {
                let input = try Tree(source.resolvingSymlinksInPath())
                let output = try Tree(target.resolvingSymlinksInPath())
                try engine.validateFolders(input.url, output.url)
                let volume = try engine.inspect(output.url)
                try engine.validateVolume(volume)
                let saved = engine.job?.target.path == output.url.path ? engine.job?.storageBookmark : nil
                let storageAccess = selectedStorage ?? saved.map { engine.scoped($0, fallback: volume.mount) }
                let disk: Tree?
                if let selectedStorage {
                    disk = try engine.selectedVolume(selectedStorage, for: volume, target: output)
                } else if let storageAccess {
                    disk = try withExtendedLifetime(storageAccess) { try engine.volumeTree(for: volume, target: output) }
                } else {
                    disk = nil
                }
                let storageBookmark = try selectedStorage.flatMap { try engine.bookmarkForStorage($0) } ?? saved
                let identity = try Self.identity(input)
                let marker = try Repository.enroll(output, volume: volume, sourceIdentity: identity, source: input.url,
                                                    host: engine.host, disk: disk)
                let configured = BackupJob(
                    id: marker.job, source: input.url, target: output.url, volumeID: volume.identifier,
                    volumeName: volume.name, format: volume.format,
                    sourceBookmark: engine.bookmark(source, readOnly: true),
                    targetBookmark: engine.bookmark(target, readOnly: false), sourceIdentity: identity,
                    targetRelativePath: try VolumeLocation(output.root).relative(output.url),
                    automatic: automatic, restoreOnly: false, reuseMatchingFiles: existingFiles == .reuseIdentical,
                    existingFiles: existingFiles, ejectAfterBackup: ejectAfterBackup, storageBookmark: storageBookmark)
                try engine.activate(configured, sourceAccess: sourceAccess, targetAccess: targetAccess, storageAccess: storageAccess)
                return configured
            }
        }
    }

    public func openExisting(target: URL, volumeRoot: URL? = nil) async throws -> BackupJob {
        try await perform { engine in
            try engine.load()
            guard engine.ejectionTask == nil else { throw BackupError.message("正在推出硬盘，请稍候") }
            let access = Scope(target)
            let storageAccess = volumeRoot.map(Scope.init)
            return try withExtendedLifetime((access, storageAccess)) {
                let output = try Tree(target.resolvingSymlinksInPath())
                let volume = try engine.inspect(output.url)
                try engine.validateVolume(volume)
                let disk = try storageAccess.map { try engine.selectedVolume($0, for: volume, target: output) }
                    ?? (try? engine.volumeTree(for: volume, target: output))
                let folder = try Repository.locatedTree(output, volume: volume, disk: disk)
                let marker = try Repository.marker(folder, volume: volume)
                let configured = BackupJob(
                    id: marker.job, source: marker.sourcePath.map { URL(fileURLWithPath: $0) } ?? output.url, target: output.url,
                    volumeID: volume.identifier, volumeName: volume.name, format: volume.format,
                    sourceBookmark: nil, targetBookmark: engine.bookmark(target, readOnly: false),
                    sourceIdentity: marker.sourceIdentity ?? "", targetRelativePath: try VolumeLocation(output.root).relative(output.url),
                    automatic: false, restoreOnly: true, storageBookmark: try storageAccess.flatMap { try engine.bookmarkForStorage($0) })
                try engine.activate(configured, sourceAccess: nil, targetAccess: access, storageAccess: storageAccess)
                return configured
            }
        }
    }

    private func activate(_ job: BackupJob, sourceAccess: Scope?, targetAccess: Scope, storageAccess: Scope? = nil) throws {
        try setJob(job)
        self.sourceScope = sourceAccess
        self.targetScope = targetAccess
        storageScope = storageAccess
        try JSONEncoder().encode(job).write(to: configURL, options: .atomic)
        setPaused(false)
        suppressConnection = false
        do { try refresh() } catch { fail(error) }
        schedule(force: true)
    }

    private func setJob(_ job: BackupJob) throws {
        let index = try Catalog(storage.appending(path: "\(job.id.uuidString).sqlite"))
        repository = nil
        targetMonitor = nil
        sourceMonitor = nil
        sourceScope = nil
        targetScope = nil
        storageScope = nil
        sourceDevice = nil
        takeover = nil
        self.job = job
        catalog = index
        progress = SyncProgress(state: .disconnected)
        progress.trackedFiles = try index.fileCount()
        progress.lastSuccess = try date("lastSuccess", catalog: index)
        progress.lastRunID = try index.latestRunID()
        publish()
    }

    public func setAutomatic(_ automatic: Bool) async throws {
        try await perform { engine in
            guard var job = engine.job, !job.restoreOnly else { return }
            job.automatic = automatic
            try JSONEncoder().encode(job).write(to: engine.configURL, options: .atomic)
            engine.job = job
            engine.publish()
            if automatic { engine.schedule(force: true) }
        }
    }

    public func setEjectAfterBackup(_ enabled: Bool) async throws {
        try await perform { engine in
            guard var job = engine.job, !job.restoreOnly else { return }
            job.ejectAfterBackup = enabled
            try JSONEncoder().encode(job).write(to: engine.configURL, options: .atomic)
            engine.job = job
            engine.publish()
        }
    }

    public func setReuseMatchingFiles(_ enabled: Bool) async throws {
        try await setExistingFilesPolicy(enabled ? .reuseIdentical : .preserve)
    }

    public func setExistingFilesPolicy(_ policy: ExistingFilesPolicy) async throws {
        try await perform { engine in
            guard var job = engine.job, !job.restoreOnly, job.existingFilesPolicy != policy else { return }
            try engine.catalog?.recordChanges(Changes(fullScan: true), side: "source")
            try engine.catalog?.recordChanges(Changes(fullScan: true), side: "target")
            job.existingFiles = policy
            job.reuseMatchingFiles = policy == .reuseIdentical
            try JSONEncoder().encode(job).write(to: engine.configURL, options: .atomic)
            engine.job = job
            engine.publish()
            engine.schedule(force: true)
        }
    }

    private func validateFolders(_ source: URL, _ target: URL) throws {
        let appData = storage.resolvingSymlinksInPath()
        guard relativePath(source, in: target) == nil, relativePath(target, in: source) == nil,
              relativePath(appData, in: source) == nil, relativePath(source, in: appData) == nil,
              relativePath(appData, in: target) == nil, relativePath(target, in: appData) == nil else {
            throw BackupError.message("源文件夹、备份位置和应用数据不能相互包含")
        }
    }

    private func validateVolume(_ volume: VolumeInfo) throws {
        if !allowInternal && !volume.isExternal { throw BackupError.message("请选择外置硬盘上的文件夹") }
    }

    private func inspect(_ folder: URL) throws -> VolumeInfo {
        let info = try VolumeInfo.inspect(folder)
        if let testFormat {
            return VolumeInfo(name: info.name, mount: info.mount, identifier: info.identifier, format: testFormat,
                              availableBytes: info.availableBytes, totalBytes: info.totalBytes, caseSensitive: info.caseSensitive,
                              isExternal: info.isExternal, device: info.device)
        }
        return info
    }

    private func bookmark(_ url: URL, readOnly: Bool) -> Data? {
        if allowInternal { return nil }
        var options: URL.BookmarkCreationOptions = [.withSecurityScope]
        if readOnly { options.insert(.securityScopeAllowOnlyReadAccess) }
        return (try? url.bookmarkData(options: options)) ?? (try? url.bookmarkData(options: .minimalBookmark))
    }

    private func scoped(_ bookmark: Data?, fallback: URL) -> Scope {
        Scope.resolving(bookmark, fallback: fallback)
    }

    private func bookmarkForStorage(_ scope: Scope) throws -> Data? {
        if allowInternal { return nil }
        return try scope.url.bookmarkData(options: [.withSecurityScope])
    }

    private func selectedVolume(_ access: Scope, for volume: VolumeInfo, target: Tree) throws -> Tree {
        let mount = volume.mount.resolvingSymlinksInPath()
        guard access.url.resolvingSymlinksInPath().path == mount.path else {
            throw BackupError.message("请选择此备份硬盘的根目录")
        }
        return try volumeTree(for: volume, target: target)
    }

    private func volumeTree(for volume: VolumeInfo, target: Tree) throws -> Tree {
        let disk = try Tree(volume.mount.resolvingSymlinksInPath())
        guard disk.device == target.device, target.url.path != disk.url.path else {
            throw BackupError.message("请选择硬盘内的一个文件夹作为备份位置")
        }
        return disk
    }

    private func storageDisk(_ job: BackupJob, tree: Tree, volume: VolumeInfo) throws -> Tree? {
        if let storageScope, storageScope.url.resolvingSymlinksInPath().path == volume.mount.resolvingSymlinksInPath().path {
            return try volumeTree(for: volume, target: tree)
        }
        if let bookmark = job.storageBookmark {
            let access = scoped(bookmark, fallback: volume.mount)
            let disk = try withExtendedLifetime(access) { try volumeTree(for: volume, target: tree) }
            storageScope = access
            return disk
        }
        if try tree.entry(identityName) != nil { return try? volumeTree(for: volume, target: tree) }
        return nil
    }

    public func organizeBackup(on volumeRoot: URL) async throws {
        try await perform { engine in
            try engine.load()
            guard var job = engine.job, engine.ejectionTask == nil else {
                throw BackupError.message("请先连接要整理的备份硬盘")
            }
            let access = Scope(volumeRoot)
            let selected = access.url.resolvingSymlinksInPath()
            let folder = selected.appending(path: job.targetRelativePath, directoryHint: .isDirectory)
            let target = try Tree(folder)
            let volume = try engine.inspect(target.url)
            try engine.validateVolume(volume)
            let disk = try engine.selectedVolume(access, for: volume, target: target)
            guard job.volumeID.isEmpty || job.volumeID.caseInsensitiveCompare(volume.identifier) == .orderedSame,
                  try Repository.jobID(target, volume: volume) == job.id else {
                throw BackupError.message("请选择原先绑定的备份硬盘")
            }
            try Repository.checkIdentitySlot(target, job: job.id, format: volume.format)
            job.storageBookmark = try engine.bookmarkForStorage(access)
            try JSONEncoder().encode(job).write(to: engine.configURL, options: .atomic)
            engine.job = job
            engine.storageScope = access
            engine.suppressConnection = false
            do {
                if let repository = engine.repository, repository.tree.url.path == target.url.path {
                    if try repository.needsRecovery() { try repository.open() }
                    try repository.organize(on: disk)
                } else {
                    engine.repository = nil
                    engine.targetMonitor = nil
                    try engine.refresh()
                }
                engine.publish()
            } catch {
                engine.repository = nil
                engine.targetMonitor = nil
                engine.fail(error)
                throw error
            }
        }
    }

    static func identity(_ tree: Tree) throws -> String {
        let location = try VolumeLocation(tree.root)
        let uuid = try location.mount.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        return "\(uuid ?? location.mount.path):\(tree.identity)"
    }

    private func sourceTree(_ job: BackupJob) throws -> Tree {
        var scope = sourceScope ?? scoped(job.sourceBookmark, fallback: job.source)
        var tree: Tree
        do {
            tree = try Tree(scope.url.resolvingSymlinksInPath())
        } catch {
            scope = scoped(job.sourceBookmark, fallback: job.source)
            guard let relocated = try? Tree(scope.url.resolvingSymlinksInPath()) else {
                sourceScope = nil
                throw BackupError.message("无法访问源文件夹：\(job.source.path)")
            }
            tree = relocated
        }
        if try Self.identity(tree) != job.sourceIdentity {
            let resolved = scoped(job.sourceBookmark, fallback: job.source)
            guard resolved.url != scope.url, let relocated = try? Tree(resolved.url.resolvingSymlinksInPath()),
                  try Self.identity(relocated) == job.sourceIdentity else {
                throw BackupError.message("源文件夹已替换，请在设置中重新选择")
            }
            scope = resolved
            tree = relocated
        }
        if let actual = tree.actualURL, actual.path != tree.url.path {
            let resolved = try Tree(actual)
            guard resolved.identity == tree.identity, resolved.device == tree.device else { throw BackupError.unstable(actual.path) }
            tree = resolved
        }
        sourceScope = scope
        return tree
    }

    private func findTarget(_ job: BackupJob) throws -> (Tree, VolumeInfo)? {
        if job.setID != nil {
            guard let volume = mappedVolume else { return nil }
            let disk = try Tree(volume.mount.resolvingSymlinksInPath())
            return (try Repository.memberTree(on: disk, folder: job.targetRelativePath, job: job.id, volume: volume), volume)
        }
        let mounts = VolumeInfo.matchingMounts(job.volumeID, format: testFormat == nil ? job.format : nil)
        guard !mounts.isEmpty else { return nil }
        // The retained scope may still name the old mount point after a volume rename.
        let primary = scoped(job.targetBookmark, fallback: job.target)
        let diskAccess = job.storageBookmark.map { scoped($0, fallback: job.target) }
        var candidates = [primary.url.resolvingSymlinksInPath()]
        if let retained = targetScope?.url.resolvingSymlinksInPath(), !candidates.contains(retained) {
            candidates.append(retained)
        }
        for mount in mounts {
            let path = job.targetRelativePath.isEmpty ? mount : mount.appending(path: job.targetRelativePath)
            let resolved = path.resolvingSymlinksInPath()
            if !candidates.contains(resolved) { candidates.append(resolved) }
        }
        var errorAtKnownLocation: Error?
        for candidate in candidates {
            guard let tree = try? Tree(candidate),
                  let volume = try? inspect(candidate),
                  job.volumeID.isEmpty || job.volumeID.caseInsensitiveCompare(volume.identifier) == .orderedSame,
                  job.format == volume.format,
                  (try? validateVolume(volume)) != nil else { continue }
            do {
                guard try Repository.jobID(tree, volume: volume) == job.id else { continue }
                if primary.url.resolvingSymlinksInPath() == candidate || targetScope == nil {
                    targetScope = primary
                }
                if let diskAccess, storageScope?.url.resolvingSymlinksInPath().path != volume.mount.resolvingSymlinksInPath().path {
                    storageScope = diskAccess
                }
                return (tree, volume)
            } catch {
                if candidate.path == candidates.first?.path { errorAtKnownLocation = error }
            }
        }
        if let errorAtKnownLocation, !job.volumeID.isEmpty {
            throw BackupError.message("找不到此任务的备份记录：\(errorAtKnownLocation.localizedDescription)")
        }
        return nil
    }

    private func updateTargetLocation(_ job: BackupJob, tree: Tree, volume: VolumeInfo) throws {
        guard job.target.path != tree.url.path || job.volumeName != volume.name ||
              (job.volumeID.isEmpty && !volume.identifier.isEmpty) else { return }
        var updated = job
        updated.target = tree.url
        updated.volumeName = volume.name
        if updated.volumeID.isEmpty { updated.volumeID = volume.identifier }
        updated.targetBookmark = bookmark(tree.url, readOnly: false) ?? job.targetBookmark
        if let saved = job.storageBookmark {
            updated.storageBookmark = (try? bookmarkForStorage(Scope(volume.mount))) ?? saved
        }
        try JSONEncoder().encode(updated).write(to: configURL, options: .atomic)
        self.job = updated
    }

    public func volumesDidChange() {
        queue.async { [weak self] in self?.updateConnection() }
    }

    func refreshConnection(available: Bool = true) async {
        try? await perform { $0.updateConnection(available: available) }
    }

    private func updateConnection(available: Bool = true) {
        guard started else { return }
        if ejectionTask != nil {
            volumeChangedWhileEjecting = true
            return
        }
        suppressConnection = false
        if !available {
            try? persistEvents(flush: false)
            stopMaintenance()
            repository = nil
            targetMonitor = nil
            sourceMonitor = nil
            sourceScope = nil
            targetScope = nil
            storageScope = nil
            mappedVolume = nil
            scheduled?.cancel()
            forceAutomatic = false
            if progress.state != .ejected {
                progress.state = .disconnected
                progress.message = nil
            }
            publish()
            return
        }
        do {
            if try refresh(updateVolume: true) { schedule(force: true) }
        } catch { fail(error) }
    }

    @discardableResult
    private func refresh(updateVolume: Bool = false) throws -> Bool {
        guard ejectionTask == nil, !suppressConnection else { return false }
        guard let job, let catalog else { publish(); return false }
        if let repository, (try? repository.tree.checkRoot()) != nil {
            if updateVolume, let volume = try? inspect(repository.tree.url) {
                try updateTargetLocation(job, tree: repository.tree, volume: volume)
                repository.updateVolume(volume)
                publish()
            }
            return false
        }
        repository = nil
        stopMaintenance()
        targetMonitor = nil
        guard let (tree, volume) = try findTarget(job) else {
            try? persistEvents(flush: false)
            sourceMonitor = nil
            sourceScope = nil
            targetScope = nil
            storageScope = nil
            if progress.state != .ejected {
                progress.state = .disconnected
                progress.message = nil
                publish()
            }
            return false
        }
        if !job.restoreOnly, let source = try? sourceTree(job) { try startSourceMonitor(source, catalog: catalog) }
        let disk = job.setID == nil ? try storageDisk(job, tree: tree, volume: volume) : nil
        let located = job.setID == nil ? try Repository.locatedTree(tree, volume: volume, disk: disk) : tree
        let next = try Repository(tree: located, volume: volume, job: job, catalog: catalog, host: host, interruption: interruption)
        repository = next
        do {
            if try next.needsRecovery() {
                progress.state = .recovering
                progress.message = nil
                publish()
            }
            if try next.open() {
                try catalog.putActivity([Activity(date: Date(), kind: .recovered, path: "备份硬盘",
                                                   detail: "已回滚未完成的更新", bytes: 0)])
            }
            if job.format == .exfat && !job.restoreOnly && !next.descriptor.portable,
               next.descriptor.sourceIdentity == job.sourceIdentity {
                try catalog.bindSource(job.sourceIdentity)
                try next.upgrade(owner: host)
            }
            if next.descriptor.portable && !job.restoreOnly, try next.owner == host,
               try catalog.generation == 0 && catalog.get("aligned.source") == nil {
                try catalog.bindSource(job.sourceIdentity)
            }
            if let disk, storageScope != nil { try next.organize(on: disk) }
            try catalog.recordChanges(Changes(fullScan: true), side: "target")
            try updateTargetLocation(job, tree: tree, volume: volume)
            startTargetMonitor(next.tree)
            progress.trackedFiles = try catalog.fileCount()
            progress.lastRunID = try catalog.latestRunID()
            progress.state = try requiresTakeover(next, job: job) ? .takeoverRequired : (isPaused ? .paused : .ready)
            progress.message = nil
            startMaintenance()
            publish()
            return true
        } catch {
            repository = nil
            throw error
        }
    }

    private func requiresTakeover(_ repo: Repository, job: BackupJob) throws -> Bool {
        if !repo.descriptor.portable || job.restoreOnly { return false }
        return try repo.owner != host || repo.catalog.get("aligned.source") != job.sourceIdentity || repo.catalog.get("takeover.pending") == "1"
    }

    private func startSourceMonitor(_ source: Tree, catalog: Catalog) throws {
        guard monitor else { return }
        if source.url.path.hasPrefix("/private/var/folders/") || source.url.path.hasPrefix("/private/tmp/") {
            sourceMonitor = nil
            streamFailure = true
            return
        }
        if let stream = sourceMonitor, stream.identity == source.identity, stream.url == source.url,
           stream.device == source.device { return }
        sourceMonitor = nil
        let uuid = EventMonitor.uuid(for: source.device) ?? ""
        let latest = EventMonitor.current(for: source.device)
        let cursor = UInt64(try catalog.get("source.cursor") ?? "") ?? 0
        let oldUUID = try catalog.get("source.stream")
        let valid = !uuid.isEmpty && oldUUID == uuid && cursor > 0 && latest >= cursor
        let baseline = valid ? cursor : latest
        do {
            sourceMonitor = try EventMonitor(tree: source, since: valid ? baseline : 0, excludeControl: false) { [weak self] in
                self?.receivedEvents()
            }
            streamFailure = false
        } catch {
            streamFailure = true
        }
        if !valid {
            try catalog.recordChanges(Changes(cursor: baseline, fullScan: true, resetCursor: true), side: "source")
            try catalog.set("source.stream", uuid)
        }
    }

    private func startTargetMonitor(_ target: Tree) {
        guard monitor else { return }
        do {
            targetMonitor = try EventMonitor(tree: target, since: 0, excludeControl: true) { [weak self] in
                self?.receivedEvents()
            }
        } catch {
            targetMonitor = nil
        }
    }

    private func receivedEvents() {
        queue.async { [weak self] in self?.schedule(force: false) }
    }

    private func schedule(force: Bool, delay: DispatchTimeInterval = .milliseconds(300)) {
        forceAutomatic = forceAutomatic || force
        scheduled?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.automaticTick() }
        scheduled = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func automaticTick() {
        let force = forceAutomatic
        forceAutomatic = false
        do {
            let changed = try persistEvents(flush: false)
            if changed { automaticRetries = 0 }
            guard let job, job.automatic, !job.restoreOnly, !isPaused, let repository, changed || force,
                  try !requiresTakeover(repository, job: job) else { return }
            if let automaticHandler {
                automaticHandler(false)
                return
            }
            _ = try run(verify: false)
            if unstableThisRun, automaticRetries < 2 {
                automaticRetries += 1
                schedule(force: true, delay: .seconds(2))
            }
        } catch { fail(error) }
    }

    @discardableResult
    private func persistEvents(flush: Bool) throws -> Bool {
        guard let catalog else { return false }
        var changed = false
        var exclusions: SourceExclusions?
        for (side, stream) in [("source", sourceMonitor), ("target", targetMonitor)] {
            guard let stream else { continue }
            var events = stream.drain(flush: flush)
            if events.paths.keys.contains(where: { $0.contains(".build") || $0.contains("dist/") }), let job, !job.restoreOnly {
                if exclusions == nil, let source = try? sourceTree(job) { exclusions = SourceExclusions(source: source) }
                if let exclusions {
                    events.paths = events.paths.filter {
                        !exclusions.contains($0.key) && (side != "source" || !exclusions.installer($0.key))
                    }
                }
            }
            if !events.empty {
                try catalog.recordChanges(events, side: side)
                changed = changed || events.fullScan || !events.paths.isEmpty
            }
            if events.resetCursor && side == "source" {
                try catalog.set("source.stream", "")
                sourceMonitor = nil
            }
        }
        return changed
    }

    public func syncNow() async throws -> SyncProgress {
        try await perform { engine in
            do {
                let result = try engine.run(verify: false)
                if engine.automaticHandler != nil, engine.unstableThisRun, engine.automaticRetries < 2 {
                    engine.automaticRetries += 1
                    engine.schedule(force: true, delay: .seconds(2))
                }
                return result
            }
            catch { engine.fail(error); throw error }
        }
    }

    public func verify() async throws -> SyncProgress {
        try await perform { engine in
            do { return try engine.run(verify: true) }
            catch { engine.fail(error); throw error }
        }
    }

    public func pause() {
        setPaused(true)
        queue.async { [weak self] in
            guard let self, self.repository != nil else { return }
            self.progress.state = .paused
            self.progress.message = nil
            self.publish()
        }
    }

    public func resume() {
        setPaused(false)
        queue.async { [weak self] in
            guard let self else { return }
            if let handler = self.automaticHandler {
                if self.repository != nil { handler(false) }
                if self.progress.state == .paused {
                    self.progress.state = self.repository == nil ? .disconnected : .ready
                    self.publish()
                }
                return
            }
            self.suppressConnection = false
            do {
                try self.refresh()
                if self.repository != nil { _ = try self.run(verify: false) }
            } catch { self.fail(error) }
        }
    }

    func bindMember(to volume: VolumeInfo?, relative: String?, source: URL? = nil) async throws {
        try await perform { engine in
            try engine.load()
            guard var job = engine.job, job.setID != nil else { return }
            if let relative { job.targetRelativePath = relative }
            if let source { job.source = source }
            if let volume {
                job.target = volume.mount.appending(path: job.targetRelativePath, directoryHint: .isDirectory)
                job.volumeName = volume.name
            }
            if engine.mappedVolume?.mount != volume?.mount || engine.job?.targetRelativePath != job.targetRelativePath {
                engine.repository = nil
                engine.targetMonitor = nil
            }
            if volume != nil, engine.mappedVolume == nil { engine.suppressConnection = false }
            engine.mappedVolume = volume
            if let volume { engine.repository?.updateVolume(volume) }
            if engine.job?.target != job.target || engine.job?.source != job.source ||
                engine.job?.volumeName != job.volumeName {
                try JSONEncoder().encode(job).write(to: engine.configURL, options: .atomic)
            }
            engine.job = job
            do { try engine.refresh(); engine.publish() }
            catch { engine.fail(error); throw error }
        }
    }

    func memberSource() async throws -> URL {
        try await perform { engine in
            guard let job = engine.job, !job.restoreOnly else { throw BackupError.message("请选择源文件夹") }
            return try engine.sourceTree(job).url
        }
    }

    func setMediumOverrides(_ values: [String: StorageMedium]) async {
        try? await perform { $0.mediumOverrides = values }
    }

    private func profile(_ source: Tree, target: VolumeInfo) -> IOProfile {
        if sourceDevice?.0 != source.device { sourceDevice = (source.device, StorageDeviceInfo.inspect(source)) }
        let device = sourceDevice!.1
        return IOProfile(source: mediumOverrides[device.identifier.uppercased()] ?? device.medium,
                         target: mediumOverrides[target.device.identifier.uppercased()] ?? target.device.medium)
    }

    func hasPendingChanges() async throws -> Bool {
        try await perform { engine in
            _ = try engine.persistEvents(flush: true)
            guard let catalog = engine.catalog else { return false }
            return try !catalog.pending("source").empty || !catalog.pending("target").empty
        }
    }

    func report(_ error: any Error) async {
        try? await perform { $0.fail(error) }
    }

    func releaseForEjection() async throws {
        try await perform { engine in
            _ = try engine.persistEvents(flush: true)
            if let repository = engine.repository {
                if try repository.needsRecovery() { try repository.open() }
                try repository.tree.checkRoot()
                try repository.tree.root.flush(directory: true)
            }
            engine.repository = nil
            engine.stopMaintenance()
            engine.targetMonitor = nil
            engine.sourceMonitor = nil
            engine.targetScope = nil
            engine.storageScope = nil
            engine.mappedVolume = nil
            engine.suppressConnection = true
            engine.scheduled?.cancel()
            engine.progress.state = .ejecting
            engine.publish()
        }
    }

    func didEject(_ failure: String?) async {
        try? await perform {
            $0.setPaused(false)
            $0.completeEjection(failure: failure, afterBackup: true)
        }
    }

    public func eject() async throws {
        setPaused(true)
        try await perform { engine in
            defer { engine.setPaused(false) }
            guard engine.ejectionTask == nil else { return }
            guard let repository = engine.repository else { throw BackupError.disconnected }
            if try repository.needsRecovery() {
                engine.progress.state = .recovering
                engine.publish()
                try repository.open()
            }
            try engine.beginEjection(repository, afterBackup: false)
        }
    }

    private func beginEjection(_ repository: Repository, afterBackup: Bool) throws {
        try repository.tree.checkRoot()
        try repository.tree.root.flush(directory: true)
        let eject = try prepareEjection(repository.volume.mount)
        self.repository = nil
        stopMaintenance()
        targetMonitor = nil
        targetScope = nil
        storageScope = nil
        suppressConnection = true
        scheduled?.cancel()
        forceAutomatic = false
        progress.state = .ejecting
        progress.message = nil
        ejectionTask = Task { [weak self] in
            guard let self else { return }
            var failure: String?
            do {
                // Wait for the sync or eject call to release its last repository reference.
                try await perform { _ in () }
                try await eject()
            } catch {
                failure = error.localizedDescription
            }
            let message = failure
            try? await perform { $0.completeEjection(failure: message, afterBackup: afterBackup) }
        }
        publish()
    }

    private func completeEjection(failure: String?, afterBackup: Bool) {
        ejectionTask = nil
        let recheck = volumeChangedWhileEjecting
        volumeChangedWhileEjecting = false
        if let failure {
            suppressConnection = false
            do { try refresh() } catch { fail(error) }
            if afterBackup && progress.state == .ready { progress.state = .upToDate }
            progress.message = afterBackup ? "备份已完成。\(failure)" : failure
        } else {
            progress.state = .ejected
            progress.message = afterBackup ? "备份已完成，可以安全拔下硬盘。" : "可以安全拔下硬盘。"
        }
        publish()
        if recheck && failure == nil { volumesDidChange() }
    }

    public func finishAndClose() async {
        setPaused(true)
        let eject = try? await perform { $0.ejectionTask }
        await eject?.value
        _ = try? await perform { engine in
            engine.scheduled?.cancel()
            engine.stopMaintenance()
            engine.sourceMonitor = nil
            engine.targetMonitor = nil
            engine.repository = nil
            engine.sourceScope = nil
            engine.targetScope = nil
            engine.storageScope = nil
        }
    }

    public func activity() async throws -> [Activity] { try await perform { try $0.catalog?.activities() ?? [] } }
    public func history() async throws -> [HistoryItem] { try await perform { try $0.catalog?.versions().map(\.item) ?? [] } }
    public func backupRuns() async throws -> [BackupRun] { try await perform { try $0.catalog?.backupRuns() ?? [] } }

    public func backupChanges(in run: UUID, kind: Activity.Kind? = nil, query: String = "",
                              limit: Int = 200, offset: Int = 0) async throws -> BackupRunChangePage {
        try await perform { engine in
            try engine.catalog?.backupChanges(in: run, kind: kind, query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                                              limit: min(500, max(1, limit)), offset: max(0, offset)) ??
                BackupRunChangePage(items: [], total: 0)
        }
    }

    private func alignmentURL(_ job: BackupJob) -> URL {
        storage.appending(path: "alignment-\(job.id.uuidString).json")
    }

    public func previewTakeover(source folder: URL) async throws -> TakeoverPreview {
        try await perform { engine in
            try engine.refresh()
            guard let job = engine.job, let repo = engine.repository, job.format == .exfat else {
                throw BackupError.message("请先连接并打开 exFAT 备份")
            }
            let access = Scope(folder)
            let source = try Tree(folder.resolvingSymlinksInPath())
            try engine.validateFolders(source.url, repo.tree.url)
            let identity = try Self.identity(source)
            let configured = BackupJob(id: job.id, source: source.url, target: repo.tree.url, volumeID: job.volumeID,
                                       volumeName: job.volumeName, format: job.format,
                                       sourceBookmark: engine.bookmark(folder, readOnly: false), targetBookmark: job.targetBookmark,
                                       sourceIdentity: identity, targetRelativePath: job.targetRelativePath,
                                       automatic: job.restoreOnly || job.automatic, restoreOnly: false,
                                       reuseMatchingFiles: job.reuseMatchingFiles, existingFiles: job.existingFiles,
                                       ejectAfterBackup: job.ejectAfterBackup, storageBookmark: job.storageBookmark,
                                       setID: job.setID)
            let checkpoint = engine.alignmentURL(job)
            if FileManager.default.fileExists(atPath: checkpoint.path) {
                var saved = try JSONDecoder().decode(AlignmentCheckpoint.self, from: Data(contentsOf: checkpoint))
                guard saved.source == identity else { throw BackupError.message("请选择上次接管使用的源文件夹") }
                saved.preview.resuming = true
                engine.takeover = (TakeoverDraft(preview: saved.preview, local: [:], disk: saved.disk), configured, access)
                return saved.preview
            }
            let local = try localAlignment(source)
            let bound = try repo.catalog.get("aligned.source") == identity
            guard bound || local.isEmpty else { throw BackupError.message("首次接管请选择一个空文件夹") }
            let base = bound ? try repo.catalog.alignment() : [:]
            let disk = try repo.verifiedAlignment()
            let preview = TakeoverPreview(id: UUID(), generation: try repo.catalog.generation,
                                          changes: compareAlignment(local: local, disk: disk, base: base))
            engine.takeover = (TakeoverDraft(preview: preview, local: local, disk: disk), configured, access)
            return preview
        }
    }

    public func confirmTakeover(_ id: UUID, choices: [String: TakeoverChoice]) async throws -> BackupJob {
        try await perform { engine in
            guard let session = engine.takeover, session.draft.preview.id == id, let repo = engine.repository,
                  session.job.id == repo.descriptor.job else { throw BackupError.message("请重新预览接管") }
            let source = try Tree(session.access.url.resolvingSymlinksInPath())
            guard try Self.identity(source) == session.job.sourceIdentity else { throw BackupError.message("源文件夹已替换") }
            let checkpointURL = engine.alignmentURL(session.job)
            let draft = session.draft
            let plan: AlignmentCheckpoint
            if draft.preview.resuming {
                plan = try JSONDecoder().decode(AlignmentCheckpoint.self, from: Data(contentsOf: checkpointURL))
                guard plan.preview.id == id, plan.source == session.job.sourceIdentity,
                      try repo.owner == plan.writer || repo.owner == engine.host,
                      try equalContents(repo.verifiedAlignment(), plan.disk) else {
                    throw BackupError.message("备份已在另一台电脑更改，无法继续上次接管")
                }
            } else {
                guard try repo.catalog.generation == draft.preview.generation,
                      try equalContents(localAlignment(source), draft.local),
                      try equalContents(repo.verifiedAlignment(), draft.disk) else {
                    throw BackupError.message("预览后文件已更改，请重新检查")
                }
                let steps = try engine.alignmentSteps(draft, choices: choices)
                plan = AlignmentCheckpoint(source: session.job.sourceIdentity, writer: try repo.owner,
                                           preview: draft.preview, disk: draft.disk, steps: steps)
                try JSONEncoder().encode(plan).write(to: checkpointURL, options: .atomic)
            }
            try repo.catalog.set("takeover.pending", "1")
            try JSONEncoder().encode(session.job).write(to: engine.configURL, options: .atomic)
            engine.job = session.job
            engine.sourceScope = session.access
            engine.sourceMonitor = nil
            engine.setPaused(false)
            engine.progress.state = .recovering
            engine.progress.message = "正在对齐源文件夹"
            engine.publish()
            do {
                if !repo.descriptor.portable { try repo.upgrade(owner: nil) }
                for step in plan.steps {
                    if engine.isPaused { throw BackupError.paused }
                    try repo.applyAlignment(step, source: source)
                }
                try source.checkRoot()
                try repo.claim()
                try repo.catalog.bindSource(session.job.sourceIdentity)
                try FileManager.default.removeItem(at: checkpointURL)
                try repo.catalog.set("takeover.pending", "0")
                try repo.catalog.recordChanges(Changes(fullScan: true), side: "target")
                engine.takeover = nil
                engine.progress.state = .ready
                engine.progress.message = nil
                engine.publish()
                engine.schedule(force: true)
                return session.job
            } catch {
                engine.fail(error)
                throw error
            }
        }
    }

    private func alignmentSteps(_ draft: TakeoverDraft, choices: [String: TakeoverChoice]) throws -> [AlignmentStep] {
        var copies: [AlignmentStep] = []
        var updates: [AlignmentStep] = []
        var removals: [AlignmentStep] = []
        for change in draft.preview.changes {
            let path = change.path
            if change.kind == .blocked { throw BackupError.message("请先处理名称或文件类型冲突：\(path)") }
            if change.kind == .send { continue }
            let local = draft.local[path]
            let incoming = draft.disk[path]
            if change.kind == .conflict {
                guard let choice = choices[path] else { throw BackupError.message("请选择如何处理冲突：\(path)") }
                if choice == .local { continue }
                if choice == .both {
                    guard change.canKeepBoth, let local else { throw BackupError.message("无法保留两份：\(path)") }
                    let copy = pathJoin(pathParent(path), "Backup Genius conflict \(UUID().uuidString)")
                    copies.append(AlignmentStep(path: copy, before: nil, desired: local, copyLocal: path))
                }
            }
            let step = AlignmentStep(path: path, before: local, desired: incoming)
            if incoming == nil { removals.append(step) } else { updates.append(step) }
        }
        func depth(_ item: AlignmentStep) -> Int { item.path.split(separator: "/").count }
        return copies + removals.sorted { depth($0) > depth($1) } + updates.sorted { depth($0) < depth($1) }
    }

    private func date(_ key: String, catalog: Catalog) throws -> Date? {
        guard let value = try catalog.get(key), let number = Double(value) else { return nil }
        return Date(timeIntervalSinceReferenceDate: number)
    }

    private func verifyDue(_ catalog: Catalog) throws -> Bool {
        if let verified = try date("lastVerify", catalog: catalog) {
            return Date().timeIntervalSince(verified) >= 7 * 86400
        }
        return false
    }

    private func fail(_ error: Error) {
        if case BackupError.paused = error {
            progress.state = .paused
            progress.message = nil
        } else if case BackupError.disconnected = error {
            progress.state = .disconnected
            progress.message = nil
        } else {
            if let repository, (try? repository.tree.checkRoot()) == nil {
                self.repository = nil
                stopMaintenance()
                targetMonitor = nil
                targetScope = nil
                progress.state = .disconnected
            } else {
                // Force a journal replay before the next attempt after an uncertain commit.
                if let repository, (try? repository.needsRecovery()) != false {
                    self.repository = nil
                    targetMonitor = nil
                }
                progress.state = .needsAttention
            }
            progress.message = error.localizedDescription
        }
        publish()
    }

    private func pruneIfDue(_ repository: Repository, now: Date = Date()) throws {
        if let last = try date("lastPrune", catalog: repository.catalog), now.timeIntervalSince(last) < 86400 { return }
        try repository.prune(now: now) { progress.historyWrittenBytes += Int64($0) }
        try repository.catalog.set("lastPrune", String(now.timeIntervalSinceReferenceDate))
    }

    private func run(verify: Bool) throws -> SyncProgress {
        guard !isPaused else { throw BackupError.paused }
        guard ejectionTask == nil else { throw BackupError.message("正在推出硬盘，请稍候") }
        try load()
        try refresh()
        guard let job, !job.restoreOnly else { throw BackupError.message("请先设置备份任务") }
        guard let repository, let scratch, let catalog else { throw BackupError.disconnected }
        if try requiresTakeover(repository, job: job) {
            progress.state = .takeoverRequired
            publish()
            return progress
        }
        let source = try sourceTree(job)
        let profile = profile(source, target: repository.volume)
        repository.ioProfile = profile
        try startSourceMonitor(source, catalog: catalog)
        try persistEvents(flush: true)
        let begin = ProcessInfo.processInfo.systemUptime
        let lastSuccess = try date("lastSuccess", catalog: catalog)
        let initial = try catalog.get("source.baseline") != "1"
        let oldCount = progress.trackedFiles
        let previousRun = progress.lastRunID
        let run = BackupRunTag(id: UUID(), started: .now)
        try catalog.beginRun(run)
        var finishedRun = false
        defer {
            if !finishedRun {
                try? catalog.finishRun(run.id, outcome: .interrupted, at: .now, issues: 0)
                progress.lastRunID = run.id
            }
        }
        progress = SyncProgress(state: verify ? .verifying : .checking, trackedFiles: oldCount,
                                unmanaged: progress.unmanaged, lastSuccess: lastSuccess)
        progress.lastRunID = previousRun
        progress.ioBufferBudget = profile.bufferBudget
        unstableThisRun = false
        publish()

        var sourceChanges = try catalog.pending("source")
        let targetChanges = try catalog.pending("target")
        let needsInstallerCleanup = try catalog.get("source.installerExclusion") != "1"
        sourceChanges.fullScan = sourceChanges.fullScan || initial || streamFailure || needsInstallerCleanup
        let planner = Planner(source: source, target: repository.tree, catalog: catalog, volume: repository.volume,
                              existingFilesPolicy: job.existingFilesPolicy)
        let plan = try planner.plan(sourceChanges: sourceChanges, targetChanges: targetChanges, verify: verify) { count in
            if isPaused { throw BackupError.paused }
            progress.examined = count
            publish(force: false)
        }
        progress.checkingSeconds = ProcessInfo.processInfo.systemUptime - begin
        progress.unmanaged = plan.unmanaged ?? progress.unmanaged
        progress.planned = plan.waves.reduce(0) { $0 + $1.count }
        progress.skipped = max(0, oldCount - plan.existingWork)
        progress.state = .syncing
        progress.currentPath = plan.waves.first?.first?.path
        publish()

        let meter = TransferProgress(total: plan.estimatedWork, at: ProcessInfo.processInfo.systemUptime)
        if progress.planned > 0 { startTransferProgress(meter) }
        defer {
            transferTimer?.cancel()
            transferTimer = nil
            transferQueue.sync {}
        }
        var problems = plan.problems
        var targetRetry = Set<String>()
        let transfer = Transfer(source: source, target: repository.tree, scratch: scratch, volume: repository.volume,
                                existingFilesPolicy: job.existingFilesPolicy, profile: profile)
        for wave in plan.waves {
            for start in stride(from: 0, to: wave.count, by: IOProfile.batchSize) {
                if isPaused { throw BackupError.paused }
                let items = Array(wave[start..<min(start + IOProfile.batchSize, wave.count)])
                progress.currentPath = items.first?.path
                meter.beginBatch(items.reduce(0) { $0 + $1.estimatedWork })
                try runBatch(items, run: run, transfer: transfer, repository: repository, meter: meter,
                             problems: &problems, targetRetry: &targetRetry)
                meter.finishBatch()
                progress.processed += items.count
                publish(force: false)
            }
        }
        try source.checkRoot()
        try repository.tree.checkRoot()
        let now = Date()
        let issues = problems.sorted(by: { $0.key < $1.key }).map {
            Activity(date: now, kind: .issue, path: $0.key, detail: $0.value, bytes: 0)
        }
        try catalog.putActivity(Array(issues.prefix(500)))
        let success = problems.isEmpty
        try catalog.finishScan(sourceRetry: problems.mapValues { _ in flagModified | flagSubtree },
                               targetRetry: targetRetry, verified: success && (verify || initial), date: success ? now : nil)
        if needsInstallerCleanup { try catalog.set("source.installerExclusion", "1") }
        if verify && success {
            try catalog.putActivity([Activity(date: now, kind: .verified, path: "备份文件", detail: "完整校验完成", bytes: 0)])
        }
        try pruneIfDue(repository)
        repository.refreshCapacity()
        let autoEject = automaticHandler == nil && job.ejectAfterBackup == true && success
        let newerChanges = try persistEvents(flush: autoEject)
        progress.trackedFiles = try catalog.fileCount()
        try catalog.finishRun(run.id, outcome: success ? .completed : .needsAttention, at: .now, issues: problems.count)
        finishedRun = true
        progress.lastRunID = run.id
        progress.issueCount = problems.count
        progress.lastSuccess = success ? now : lastSuccess
        progress.elapsedSeconds = ProcessInfo.processInfo.systemUptime - begin
        progress.state = success ? .upToDate : .needsAttention
        progress.message = issues.first?.detail
        progress.currentPath = nil
        publish()
        let completed = progress
        if newerChanges {
            schedule(force: true)
        } else if autoEject && !isPaused {
            do { try beginEjection(repository, afterBackup: true) }
            catch {
                progress.message = "备份已完成。\(error.localizedDescription)"
                publish()
            }
        }
        return completed
    }

    private func runBatch(_ items: [Work], run: BackupRunTag, transfer: Transfer, repository: Repository, meter: TransferProgress,
                          problems: inout [String: String], targetRetry: inout Set<String>) throws {
        let results = PreparationResults(count: items.count)
        let workers = min(items.count, transfer.profile.workers)
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            for index in stride(from: worker, to: items.count, by: workers) {
                results.set(Result {
                    try transfer.prepare(items[index]) { meter.record(read: $0, written: $1) }
                }, at: index)
            }
        }

        var batch = try repository.newBatch()
        batch.run = run
        let writer = PackWriter(repository: repository, id: batch.id) { meter.record(written: $0) }
        var patches: [String: PatchData] = [:]
        var applying: [Work] = []
        var adoptedEntries = 0
        var reusedFiles = 0
        let staging = results.result()
        defer {
            if (try? repository.needsRecovery()) == false {
                for case let .success(prepared) in staging {
                    if let id = prepared.edit?.staging { try? repository.tree.removeOwnedTree(staged(id)) }
                }
            }
        }

        for (item, result) in zip(items, staging) {
            do {
                let prepared = try result.get()
                progress.sourceReadBytes += prepared.sourceBytes
                progress.targetReadBytes += prepared.targetBytes
                progress.latestWrittenBytes += prepared.latestBytes - (prepared.patch?.bytes ?? 0)
                progress.sourceReadRequests += prepared.sourceReadRequests
                progress.targetReadRequests += prepared.targetReadRequests
                progress.latestWriteRequests += prepared.latestWriteRequests
                guard var edit = prepared.edit else {
                    if item.stamp?.kind == .regular || item.stamp?.kind == .symlink { progress.skipped += 1 }
                    continue
                }
                if prepared.archive {
                    edit.archive = try repository.archive(edit, old: item.old, knownHashes: prepared.oldHashes, writer: writer) {
                        progress.targetReadBytes += Int64($0)
                        progress.targetReadRequests += 1
                        meter.record(read: $0)
                    }
                }
                if let patch = prepared.patch { patches[edit.path] = patch }
                batch.edits.append(edit)
                applying.append(item)
                if let adoption = prepared.adoption {
                    adoptedEntries += 1
                    if adoption == .reusedFile || adoption == .reusedLink { reusedFiles += 1 }
                }
            } catch {
                try note(error, for: item.path, problems: &problems)
                targetRetry.insert(item.path)
            }
        }
        guard !batch.edits.isEmpty else { return }
        batch.chunks = try writer.finish()
        progress.historyWrittenBytes += writer.bytes
        do {
            try repository.commit(batch, patches: patches, onWrite: { meter.record(written: $0) }) {
                try transfer.source.checkRoot()
                let exclusions = SourceExclusions(source: transfer.source)
                for item in applying {
                    if item.retireInstaller {
                        guard exclusions.installer(item.path) else { throw BackupError.unstable(item.path) }
                        continue
                    }
                    guard try transfer.source.entry(item.path) == item.stamp else { throw BackupError.unstable(item.path) }
                    if let from = item.from, !item.caseOnly, try transfer.source.entry(from) != nil {
                        throw BackupError.unstable(from)
                    }
                }
            }
            progress.latestWrittenBytes += patches.values.reduce(0) { $0 + $1.bytes }
            progress.latestWriteRequests += patches.values.reduce(0) { $0 + $1.writeRequests(window: transfer.profile.targetWindow) }
            progress.unmanaged = max(0, progress.unmanaged - adoptedEntries)
            progress.skipped += reusedFiles
            if reusedFiles > 0 { progress.reusedFiles = (progress.reusedFiles ?? 0) + reusedFiles }
        } catch BackupError.unstable(let path) {
            for item in applying {
                problems[item.path] = "等待文件稳定：\(path)"
                targetRetry.insert(item.path)
            }
            unstableThisRun = true
        }
    }

    private func note(_ error: Error, for path: String, problems: inout [String: String]) throws {
        if case let BackupError.io(_, _, code) = error, [ENOSPC, EDQUOT, EIO, ENXIO, ENODEV, EROFS].contains(code) { throw error }
        if case BackupError.unstable = error { unstableThisRun = true }
        problems[path] = error.localizedDescription
    }

    func simulate(source: Changes, target: Changes = Changes()) async throws {
        try await perform { engine in
            try engine.catalog?.recordChanges(source, side: "source")
            try engine.catalog?.recordChanges(target, side: "target")
        }
    }

    func maintenance(now: Date) async throws {
        try await perform { engine in
            try engine.refresh()
            guard let repo = engine.repository else { throw BackupError.disconnected }
            try repo.prune(now: now, onWrite: { _ in })
        }
    }

    public func restore(_ version: UUID? = nil, to folder: URL) async throws -> URL {
        try await perform { engine in
            try engine.refresh()
            guard let repo = engine.repository, let catalog = engine.catalog else { throw BackupError.disconnected }
            let access = Scope(folder)
            return try withExtendedLifetime(access) {
                let output = try Tree(folder.resolvingSymlinksInPath())
                guard relativePath(output.url, in: repo.tree.url) == nil else {
                    throw BackupError.message("请选择备份目录之外的恢复位置")
                }
                let format = try VolumeLocation(output.root).formatName
                guard format != "exfat" else { throw BackupError.message("请选择支持 Mac 文件属性的恢复位置") }
                let staging = ".backup-genius-restore-\(UUID().uuidString)"
                try output.mkdir(staging)
                defer { try? output.removeOwnedTree(staging) }
                if let version {
                    guard let archive = try catalog.version(version) else { throw BackupError.message("此历史版本已过期") }
                    let path = pathJoin(staging, pathName(archive.item.path))
                    try repo.materialize(archive, on: output, at: path, rich: true)
                } else {
                    try engine.restoreCurrent(repo, catalog: catalog, output: output, staging: staging)
                }
                let date = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                    .replacingOccurrences(of: ":", with: "-")
                let name = "Backup Genius 恢复 \(date)-\(UUID().uuidString.prefix(4))"
                try output.rename(staging, to: name)
                try output.root.flush(directory: true)
                return output.url.appending(path: name, directoryHint: .isDirectory)
            }
        }
    }

    private func restoreCurrent(_ repo: Repository, catalog: Catalog, output: Tree, staging: String) throws {
        var directories: [(String, MacAttributes)] = []
        try catalog.visitFiles { record in
            try userPath(record.path)
            let path = pathJoin(staging, record.path)
            try output.makeParents(of: path)
            switch record.source.kind {
            case .regular:
                let source = try repo.tree.file(record.path)
                let destination = try output.createFile(path)
                try copyVerified(source, to: destination, length: record.source.size, hashes: record.hashes)
                try destination.apply(record.attributes, rich: true)
                try destination.flush()
            case .directory:
                try output.mkdir(path, existing: true)
                directories.append((path, record.attributes))
            case .symlink:
                let link = try macLink(record.link, attributes: record.attributes, at: record.path)
                try output.createLink(link, at: path)
                try output.applyLinkTime(record.attributes, at: path)
            case .unsupported:
                throw BackupError.message("不支持的文件：\(record.path)")
            }
        }
        for (path, attributes) in directories.sorted(by: { $0.0.count > $1.0.count }) {
            try output.directory(path).apply(attributes, rich: true)
        }
    }

    deinit {
        scheduled?.cancel()
        timer?.cancel()
    }
}
