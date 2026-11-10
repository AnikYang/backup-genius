import Foundation
import Darwin

public struct BackupPresentation: Sendable {
    public let job: BackupJob?
    public let volume: VolumeInfo?
    public let progress: SyncProgress
}

private struct Subscribers {
    var latest = BackupPresentation(job: nil, volume: nil, progress: SyncProgress())
    var streams: [UUID: AsyncStream<SyncProgress>.Continuation] = [:]
}

private final class Scope {
    let url: URL
    private let accessed: Bool

    init(_ url: URL) {
        self.url = url
        accessed = url.startAccessingSecurityScopedResource()
    }

    deinit { if accessed { url.stopAccessingSecurityScopedResource() } }
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
    private let queue = DispatchQueue(label: "backupgenius.engine", qos: .utility)
    private let publishedLock = NSLock()
    private var subscribers = Subscribers()
    private let pauseLock = NSLock()
    private var pauseRequested = false

    private let storage: URL
    private let allowInternal: Bool
    private let monitor: Bool
    private let testFormat: DiskFormat?
    private let interruption: (@Sendable (InterruptionPoint) throws -> Void)?
    private var started = false
    private var job: BackupJob?
    private var catalog: Catalog?
    private var repository: Repository?
    private var scratch: Tree?
    private var sourceScope: Scope?
    private var targetScope: Scope?
    private var sourceMonitor: EventMonitor?
    private var targetMonitor: EventMonitor?
    private var streamFailure = false
    private var scheduled: DispatchWorkItem?
    private var forceAutomatic = false
    private var automaticRetries = 0
    private var unstableThisRun = false
    private var timer: DispatchSourceTimer?
    private var suppressConnection = false
    private var progress = SyncProgress()
    private var lastPublished: Double = 0
    private var host = UUID()
    private var takeover: (draft: TakeoverDraft, job: BackupJob, access: Scope)?

    public convenience init(storage: URL) {
        self.init(storage: storage, allowInternal: false, monitor: true)
    }

    public static func testing(storage: URL, allowInternal: Bool) -> SyncEngine {
        SyncEngine(storage: storage, allowInternal: allowInternal, monitor: true)
    }

    init(storage: URL, allowInternal: Bool, monitor: Bool, testFormat: DiskFormat? = nil,
         interruption: (@Sendable (InterruptionPoint) throws -> Void)? = nil) {
        self.storage = storage
        self.allowInternal = allowInternal
        self.monitor = monitor
        self.testFormat = testFormat
        self.interruption = interruption
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
        guard force || now - lastPublished >= 0.2 else { return }
        lastPublished = now
        let snapshot = BackupPresentation(job: job, volume: repository?.volume, progress: progress)
        publishedLock.withLock {
            subscribers.latest = snapshot
            for stream in subscribers.streams.values { stream.yield(snapshot.progress) }
        }
    }

    private var configURL: URL { storage.appending(path: "job.json") }

    public func start() async throws {
        try await perform { engine in
            do {
                try engine.load()
                try engine.refresh()
                engine.schedule(force: true)
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
        if FileManager.default.fileExists(atPath: hostURL.path) {
            guard let saved = UUID(uuidString: try String(contentsOf: hostURL, encoding: .utf8)) else {
                throw BackupError.message("本机备份标识无效")
            }
            host = saved
        } else {
            try host.uuidString.write(to: hostURL, atomically: true, encoding: .utf8)
        }
        let scratchURL = storage.appending(path: "scratch", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratchURL, withIntermediateDirectories: true)
        scratch = try Tree(scratchURL.resolvingSymlinksInPath())
        if FileManager.default.fileExists(atPath: configURL.path) {
            let loaded = try JSONDecoder().decode(BackupJob.self, from: Data(contentsOf: configURL))
            try setJob(loaded)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(60), repeating: .seconds(60), leeway: .seconds(10))
        timer.setEventHandler { [weak self] in self?.periodic() }
        self.timer = timer
        timer.resume()
        started = true
    }

    private func periodic() {
        guard let job, let repository, !isPaused else { return }
        do {
            guard try !requiresTakeover(repository, job: job), !job.restoreOnly || !repository.descriptor.portable else { return }
            let due = try verifyDue(repository.catalog)
            if !job.restoreOnly, job.automatic, due || streamFailure {
                _ = try run(verify: due)
            } else {
                try pruneIfDue(repository)
            }
        } catch { fail(error) }
    }

    public func configure(source: URL, target: URL, automatic: Bool = true, reuseMatchingFiles: Bool = false) async throws -> BackupJob {
        try await configure(source: source, target: target, automatic: automatic,
                            existingFiles: reuseMatchingFiles ? .reuseIdentical : .preserve)
    }

    public func configure(source: URL, target: URL, automatic: Bool = true,
                          existingFiles: ExistingFilesPolicy) async throws -> BackupJob {
        try await perform { engine in
            try engine.load()
            let sourceAccess = Scope(source)
            let targetAccess = Scope(target)
            return try withExtendedLifetime((sourceAccess, targetAccess)) {
                let input = try Tree(source.resolvingSymlinksInPath())
                let output = try Tree(target.resolvingSymlinksInPath())
                try engine.validateFolders(input.url, output.url)
                let volume = try engine.inspect(output.url)
                try engine.validateVolume(volume)
                let identity = try engine.identity(input)
                let marker = try Repository.enroll(output, volume: volume, sourceIdentity: identity, source: input.url, host: engine.host)
                let configured = BackupJob(
                    id: marker.job, source: input.url, target: output.url, volumeID: volume.identifier,
                    volumeName: volume.name, format: volume.format,
                    sourceBookmark: engine.bookmark(source, readOnly: true),
                    targetBookmark: engine.bookmark(target, readOnly: false), sourceIdentity: identity,
                    targetRelativePath: try VolumeLocation(output.root).relative(output.url),
                    automatic: automatic, restoreOnly: false, reuseMatchingFiles: existingFiles == .reuseIdentical,
                    existingFiles: existingFiles)
                try engine.activate(configured, sourceAccess: sourceAccess, targetAccess: targetAccess)
                return configured
            }
        }
    }

    public func openExisting(target: URL) async throws -> BackupJob {
        try await perform { engine in
            try engine.load()
            let access = Scope(target)
            return try withExtendedLifetime(access) {
                let output = try Tree(target.resolvingSymlinksInPath())
                let volume = try engine.inspect(output.url)
                try engine.validateVolume(volume)
                let marker = try Repository.marker(output, volume: volume)
                let configured = BackupJob(
                    id: marker.job, source: marker.sourcePath.map { URL(fileURLWithPath: $0) } ?? output.url, target: output.url,
                    volumeID: volume.identifier, volumeName: volume.name, format: volume.format,
                    sourceBookmark: nil, targetBookmark: engine.bookmark(target, readOnly: false),
                    sourceIdentity: marker.sourceIdentity ?? "", targetRelativePath: try VolumeLocation(output.root).relative(output.url),
                    automatic: false, restoreOnly: true)
                try engine.activate(configured, sourceAccess: nil, targetAccess: access)
                return configured
            }
        }
    }

    private func activate(_ job: BackupJob, sourceAccess: Scope?, targetAccess: Scope) throws {
        try setJob(job)
        self.sourceScope = sourceAccess
        self.targetScope = targetAccess
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
        takeover = nil
        self.job = job
        catalog = index
        progress = SyncProgress()
        progress.trackedFiles = try index.fileCount()
        progress.lastSuccess = try date("lastSuccess", catalog: index)
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
                              isExternal: info.isExternal, isSolidState: info.isSolidState)
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
        if let bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                       relativeTo: nil, bookmarkDataIsStale: &stale) {
                return Scope(resolved)
            }
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: .withoutUI,
                                       relativeTo: nil, bookmarkDataIsStale: &stale) {
                return Scope(resolved)
            }
        }
        return Scope(fallback)
    }

    private func identity(_ tree: Tree) throws -> String {
        let location = try VolumeLocation(tree.root)
        let uuid = try location.mount.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        return "\(uuid ?? location.mount.path):\(tree.identity)"
    }

    private func sourceTree(_ job: BackupJob) throws -> Tree {
        let scope = sourceScope ?? scoped(job.sourceBookmark, fallback: job.source)
        let tree: Tree
        do {
            tree = try Tree(scope.url.resolvingSymlinksInPath())
        } catch {
            sourceScope = nil
            throw BackupError.message("无法访问源文件夹：\(job.source.path)")
        }
        guard try identity(tree) == job.sourceIdentity else {
            throw BackupError.message("源文件夹已替换，请在设置中重新选择")
        }
        sourceScope = scope
        return tree
    }

    private func findTarget(_ job: BackupJob) throws -> (Tree, VolumeInfo)? {
        let primary = targetScope ?? scoped(job.targetBookmark, fallback: job.target)
        var candidates = [primary.url.resolvingSymlinksInPath()]
        if let mounts = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []) {
            for mount in mounts {
                if !job.volumeID.isEmpty, let uuid = try? mount.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
                   uuid != job.volumeID { continue }
                let path = job.targetRelativePath.isEmpty ? mount : mount.appending(path: job.targetRelativePath)
                let resolved = path.resolvingSymlinksInPath()
                if !candidates.contains(resolved) { candidates.append(resolved) }
            }
        }
        var errorAtKnownLocation: Error?
        for candidate in candidates {
            guard let tree = try? Tree(candidate),
                  let volume = try? inspect(candidate),
                  job.volumeID.isEmpty || job.volumeID == volume.identifier,
                  job.format == volume.format,
                  (try? validateVolume(volume)) != nil else { continue }
            do {
                let marker = try Repository.marker(tree, volume: volume)
                guard marker.job == job.id else { continue }
                targetScope = primary
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

    public func volumesDidChange() {
        queue.async { [weak self] in
            guard let self, self.started else { return }
            self.suppressConnection = false
            do {
                let existing = self.repository?.tree.url
                try self.refresh()
                if existing != self.repository?.tree.url { self.schedule(force: true) }
            } catch { self.fail(error) }
        }
    }

    private func refresh() throws {
        guard let job, let catalog else { publish(); return }
        if !job.restoreOnly, let source = try? sourceTree(job) { try startSourceMonitor(source, catalog: catalog) }
        if let repository, (try? repository.tree.checkRoot()) != nil { return }
        repository = nil
        targetMonitor = nil
        guard !suppressConnection, let (tree, volume) = try findTarget(job) else {
            targetScope = nil
            progress.state = .disconnected
            progress.message = nil
            publish()
            return
        }
        let next = try Repository(tree: tree, volume: volume, job: job, catalog: catalog, host: host, interruption: interruption)
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
            try catalog.recordChanges(Changes(fullScan: true), side: "target")
            startTargetMonitor(tree)
            progress.trackedFiles = try catalog.fileCount()
            progress.state = try requiresTakeover(next, job: job) ? .takeoverRequired : (isPaused ? .paused : .ready)
            progress.message = nil
            publish()
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
            if events.paths.keys.contains(where: { $0.contains(".build") }), let job, !job.restoreOnly {
                if exclusions == nil, let source = try? sourceTree(job) { exclusions = SourceExclusions(source: source) }
                if let exclusions {
                    events.paths = events.paths.filter { !exclusions.contains($0.key) }
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
            do { return try engine.run(verify: false) }
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
            guard let self, self.job != nil else { return }
            self.progress.state = .paused
            self.progress.message = nil
            self.publish()
        }
    }

    public func resume() {
        setPaused(false)
        queue.async { [weak self] in
            guard let self else { return }
            self.suppressConnection = false
            do {
                try self.refresh()
                if self.repository != nil { _ = try self.run(verify: false) }
            } catch { self.fail(error) }
        }
    }

    public func prepareToEject() async throws -> URL {
        setPaused(true)
        return try await perform { engine in
            guard let repository = engine.repository else { throw BackupError.disconnected }
            if try repository.needsRecovery() {
                engine.progress.state = .recovering
                engine.publish()
                try repository.open()
            }
            try repository.tree.root.flush(directory: true)
            let mount = repository.volume.mount
            engine.repository = nil
            engine.targetMonitor = nil
            engine.targetScope = nil
            engine.suppressConnection = true
            engine.setPaused(false)
            engine.progress.state = .disconnected
            engine.progress.message = nil
            engine.publish()
            return mount
        }
    }

    public func finishAndClose() async {
        setPaused(true)
        _ = try? await perform { engine in
            engine.scheduled?.cancel()
            engine.timer?.cancel()
            engine.sourceMonitor = nil
            engine.targetMonitor = nil
            engine.repository = nil
            engine.sourceScope = nil
            engine.targetScope = nil
        }
    }

    public func activity() async throws -> [Activity] { try await perform { try $0.catalog?.activities() ?? [] } }
    public func history() async throws -> [HistoryItem] { try await perform { try $0.catalog?.versions().map(\.item) ?? [] } }

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
            let identity = try engine.identity(source)
            let configured = BackupJob(id: job.id, source: source.url, target: repo.tree.url, volumeID: job.volumeID,
                                       volumeName: job.volumeName, format: job.format,
                                       sourceBookmark: engine.bookmark(folder, readOnly: false), targetBookmark: job.targetBookmark,
                                       sourceIdentity: identity, targetRelativePath: job.targetRelativePath,
                                       automatic: job.restoreOnly || job.automatic, restoreOnly: false,
                                       reuseMatchingFiles: job.reuseMatchingFiles, existingFiles: job.existingFiles)
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
            guard try engine.identity(source) == session.job.sourceIdentity else { throw BackupError.message("源文件夹已替换") }
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
        try startSourceMonitor(source, catalog: catalog)
        try persistEvents(flush: true)
        let begin = ProcessInfo.processInfo.systemUptime
        let lastSuccess = try date("lastSuccess", catalog: catalog)
        let initial = try catalog.get("source.baseline") != "1"
        let oldCount = progress.trackedFiles
        progress = SyncProgress(state: verify ? .verifying : .checking, trackedFiles: oldCount,
                                unmanaged: progress.unmanaged, lastSuccess: lastSuccess)
        unstableThisRun = false
        publish()

        var sourceChanges = try catalog.pending("source")
        let targetChanges = try catalog.pending("target")
        sourceChanges.fullScan = sourceChanges.fullScan || initial || streamFailure
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
        publish()

        var problems = plan.problems
        var targetRetry = Set<String>()
        let transfer = Transfer(source: source, target: repository.tree, scratch: scratch, volume: repository.volume,
                                existingFilesPolicy: job.existingFilesPolicy)
        for wave in plan.waves {
            for start in stride(from: 0, to: wave.count, by: 128) {
                if isPaused { throw BackupError.paused }
                let items = Array(wave[start..<min(start + 128, wave.count)])
                progress.currentPath = items.first?.path
                try runBatch(items, transfer: transfer, repository: repository, problems: &problems, targetRetry: &targetRetry)
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
        if verify && success {
            try catalog.putActivity([Activity(date: now, kind: .verified, path: "备份文件", detail: "完整校验完成", bytes: 0)])
        }
        try pruneIfDue(repository)
        repository.refreshCapacity()
        progress.trackedFiles = try catalog.fileCount()
        progress.issueCount = problems.count
        progress.lastSuccess = success ? now : lastSuccess
        progress.elapsedSeconds = ProcessInfo.processInfo.systemUptime - begin
        progress.state = success ? .upToDate : .needsAttention
        progress.message = issues.first?.detail
        progress.currentPath = nil
        publish()
        if try persistEvents(flush: false) { schedule(force: true) }
        return progress
    }

    private func runBatch(_ items: [Work], transfer: Transfer, repository: Repository,
                          problems: inout [String: String], targetRetry: inout Set<String>) throws {
        let results = PreparationResults(count: items.count)
        let workers = min(items.count, repository.volume.isSolidState ? 4 : 1)
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            for index in stride(from: worker, to: items.count, by: workers) {
                results.set(Result { try transfer.prepare(items[index]) }, at: index)
            }
        }

        var batch = try repository.newBatch()
        let writer = PackWriter(repository: repository, id: batch.id)
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
                guard var edit = prepared.edit else {
                    if item.stamp?.kind == .regular || item.stamp?.kind == .symlink { progress.skipped += 1 }
                    continue
                }
                if prepared.archive {
                    edit.archive = try repository.archive(edit, old: item.old, knownHashes: prepared.oldHashes, writer: writer) {
                        progress.targetReadBytes += Int64($0)
                    }
                }
                if let patch = prepared.patch { patches[edit.path] = patch }
                batch.edits.append(edit)
                applying.append(item)
                if let adoption = prepared.adoption {
                    adoptedEntries += 1
                    if adoption == .reusedFile { reusedFiles += 1 }
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
            try repository.commit(batch, patches: patches) {
                try transfer.source.checkRoot()
                for item in applying {
                    guard try transfer.source.entry(item.path) == item.stamp else { throw BackupError.unstable(item.path) }
                    if let from = item.from, !item.caseOnly, try transfer.source.entry(from) != nil {
                        throw BackupError.unstable(from)
                    }
                }
            }
            progress.latestWrittenBytes += patches.values.reduce(0) { $0 + $1.bytes }
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
