import Foundation

public struct BackupFolderStatus: Identifiable, Sendable {
    public let job: BackupJob
    public let mapping: FolderMapping?
    public let snapshot: BackupPresentation
    public var id: UUID { job.id }
    public var title: String { mapping?.folder ?? job.target.lastPathComponent }
}

public struct CoordinatorPresentation: Sendable {
    public let folders: [BackupFolderStatus]
    public let running: UUID?
    public let busy: Bool
    public let diskProgress: [String: SyncProgress]
    public let media: [String: StorageMedium]
}

public actor BackupCoordinator {
    public nonisolated let legacy: SyncEngine

    private struct Binding: Codable, Sendable {
        let id: UUID
        let volumeID: String
        var mount: URL
        let bookmark: Data?
        var jobs: [UUID]
    }

    private struct PendingSetup: Codable {
        let binding: Binding
        let revision: Int64
        let jobs: [BackupJob]
    }

    private struct Draft {
        let preview: BackupSetupPreview
        let access: Scope
        let current: BackupSet?
        let sources: [UUID: (Scope, String)]
    }

    private let root: URL
    private let queue = DispatchQueue(label: "backupgenius.disk", qos: .utility)
    private let allowInternal: Bool
    private let monitor: Bool
    private let prepareEjection: @Sendable (URL) throws -> DiskEjectAction
    private let interrupt: (@Sendable (SetInterruption) throws -> Void)?
    private var host = UUID()
    private var started = false
    private var closing = false
    private var bindings: [UUID: Binding] = [:]
    private var sets: [UUID: BackupSet] = [:]
    private var stores: [UUID: BackupSetStore] = [:]
    private var engines: [UUID: SyncEngine] = [:]
    private var observers: [Task<Void, Never>] = []
    private var continuations: [UUID: AsyncStream<CoordinatorPresentation>.Continuation] = [:]
    private var draft: Draft?
    private var busy = false
    private var running: UUID?
    private var paused = false
    private var refreshRequested = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var automatic: [UUID: Bool] = [:]
    private var automaticTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var ejectedVolumes = Set<String>()
    private var diskProgress: [String: SyncProgress] = [:]
    private var media: [String: StorageMedium] = [:]

    public init(storage: URL) {
        root = storage
        allowInternal = false
        monitor = true
        prepareEjection = BackupDisk.prepare
        interrupt = nil
        legacy = SyncEngine(storage: storage, allowInternal: false, monitor: true, queue: queue)
    }

    init(storage: URL, monitor: Bool = false, prepareEjection: @escaping @Sendable (URL) throws -> DiskEjectAction = BackupDisk.prepare,
         interruption: (@Sendable (SetInterruption) throws -> Void)? = nil) {
        root = storage
        allowInternal = true
        self.monitor = monitor
        self.prepareEjection = prepareEjection
        interrupt = interruption
        legacy = SyncEngine(storage: storage, allowInternal: true, monitor: monitor, queue: queue)
    }

    private var directory: URL { root.appending(path: "collections", directoryHint: .isDirectory) }
    private var mediaURL: URL { root.appending(path: "storage-media.json") }
    private func local(_ id: UUID) -> URL { directory.appending(path: id.uuidString, directoryHint: .isDirectory) }
    private func jobsDirectory(_ id: UUID, _ job: UUID) -> URL {
        local(id).appending(path: job.uuidString, directoryHint: .isDirectory)
    }

    public func start() async throws {
        guard !started else { return }
        started = true
        busy = true
        defer { endOperation() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        host = try SyncEngine.hostID(at: root.appending(path: "host-id"))
        if let saved = try? Data(contentsOf: mediaURL) { media = try JSONDecoder().decode([String: StorageMedium].self, from: saved) }
        try await legacy.coordinate { [weak self] verify in Task { await self?.enqueue(nil, verify: verify) } }
        observe(legacy)
        await legacy.setMediumOverrides(media)
        try? await legacy.start()
        for location in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: location.lastPathComponent) else { continue }
            let url = location.appending(path: "set.json")
            let pending = try loadPending(id)
            if FileManager.default.fileExists(atPath: url.path) {
                let saved = try JSONDecoder().decode(Binding.self, from: Data(contentsOf: url))
                guard saved.id == id else { throw BackupError.message("本机备份集合标识不符") }
                bindings[id] = saved
                if let data = try? Data(contentsOf: location.appending(path: "layout.json")) {
                    sets[id] = try? JSONDecoder().decode(BackupSet.self, from: data)
                }
                await loadEngines(saved)
            } else if let pending, pending.binding.id == id {
                bindings[id] = pending.binding
            }
        }
        await reconnect()
    }

    private var allEngines: [SyncEngine] { [legacy] + Array(engines.values) }

    public func engine(for id: UUID) -> SyncEngine? {
        legacy.presentation.job?.id == id ? legacy : engines[id]
    }

    public var presentation: CoordinatorPresentation {
        let folders = allEngines.compactMap { engine -> BackupFolderStatus? in
            let snapshot = engine.presentation
            guard let job = snapshot.job else { return nil }
            let mapping = job.setID.flatMap { sets[$0]?.mappings.first(where: { $0.job == job.id }) }
            return BackupFolderStatus(job: job, mapping: mapping, snapshot: snapshot)
        }.sorted { lhs, rhs in
            if lhs.job.setID == nil { return rhs.job.setID != nil }
            if rhs.job.setID == nil { return false }
            return (lhs.job.volumeName, lhs.title, lhs.id.uuidString) < (rhs.job.volumeName, rhs.title, rhs.id.uuidString)
        }
        return CoordinatorPresentation(folders: folders, running: running, busy: busy, diskProgress: diskProgress, media: media)
    }

    public func updates() -> AsyncStream<CoordinatorPresentation> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(presentation)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }

    private func removeObserver(_ id: UUID) { continuations.removeValue(forKey: id) }

    private func observe(_ engine: SyncEngine) {
        observers.append(Task { [weak self] in
            for await _ in engine.updates() {
                guard let self else { return }
                await self.queuePublication()
            }
        })
    }

    private func queuePublication() {
        guard progressTask == nil else { return }
        progressTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            if !Task.isCancelled { await self?.publishProgress() }
        }
    }

    private func publishProgress() {
        progressTask = nil
        publish()
    }

    private func publish() {
        let snapshot = presentation
        for continuation in continuations.values { continuation.yield(snapshot) }
    }

    private func beginOperation() throws {
        guard !busy, !closing else { throw BackupError.message("请等待当前备份操作完成") }
        busy = true
        publish()
    }

    private func endOperation() {
        running = nil
        busy = false
        publish()
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
        if refreshRequested && !closing { Task { await volumesDidChange() } }
        else { scheduleAutomatic() }
    }

    private func pendingURL(_ id: UUID) -> URL { local(id).appending(path: "pending.json") }

    private func loadPending(_ id: UUID) throws -> PendingSetup? {
        let url = pendingURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(PendingSetup.self, from: Data(contentsOf: url))
    }

    private func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    private func finalize(_ pending: PendingSetup, set: BackupSet) throws {
        guard set.id == pending.binding.id, set.revision >= pending.revision,
              Set(pending.binding.jobs).isSubset(of: Set(set.mappings.map(\.job))) else {
            throw BackupError.message("磁盘上的映射与待保存的任务不符")
        }
        for job in pending.jobs {
            let url = jobsDirectory(set.id, job.id).appending(path: "job.json")
            if !FileManager.default.fileExists(atPath: url.path) { try save(job, to: url) }
        }
        try save(set, to: local(set.id).appending(path: "layout.json"))
        try save(pending.binding, to: local(set.id).appending(path: "set.json"))
        bindings[set.id] = pending.binding
        sets[set.id] = set
        if FileManager.default.fileExists(atPath: pendingURL(set.id).path) {
            try FileManager.default.removeItem(at: pendingURL(set.id))
        }
    }

    private func loadEngines(_ binding: Binding) async {
        for job in binding.jobs where engines[job] == nil {
            let engine = SyncEngine(storage: jobsDirectory(binding.id, job), allowInternal: allowInternal,
                                    monitor: monitor, queue: queue, host: host,
                                    automaticHandler: { [weak self] verify in Task { await self?.enqueue(job, verify: verify) } })
            engines[job] = engine
            observe(engine)
            await engine.setMediumOverrides(media)
            try? await engine.start()
        }
    }

    public func volumesDidChange(connected: Bool = false) async {
        guard started, !closing else { return }
        if connected { ejectedVolumes.removeAll() }
        if busy { refreshRequested = true; return }
        refreshRequested = false
        busy = true
        defer { endOperation() }
        legacy.volumesDidChange()
        await reconnect()
    }

    private func resolve(_ binding: Binding) -> (Scope, VolumeInfo)? {
        let access = Scope.resolving(binding.bookmark, fallback: binding.mount)
        let mounts = VolumeInfo.matchingMounts(binding.volumeID, format: sets[binding.id]?.format)
        guard !mounts.isEmpty else { return nil }
        for path in mounts {
            if let info = try? VolumeInfo.inspect(path), info.identifier.caseInsensitiveCompare(binding.volumeID) == .orderedSame {
                return (access, info)
            }
        }
        return nil
    }

    private func reconnect() async {
        for binding in Array(bindings.values) {
            let id = binding.id, volumeID = binding.volumeID.uppercased()
            if let old = stores[id], (try? old.disk.checkRoot()) == nil { stores[id] = nil }
            guard let (access, volume) = resolve(binding) else {
                stores[id] = nil
                ejectedVolumes.remove(volumeID)
                for job in binding.jobs { try? await engines[job]?.bindMember(to: nil, relative: nil) }
                continue
            }
            guard !ejectedVolumes.contains(volumeID) else { continue }
            do {
                let alreadyOpen = stores[id] != nil
                let store = try stores[id] ?? BackupSetStore(access, volume: volume, interrupt: interrupt)
                store.volume = volume
                guard let set = try store.recover(), set.id == id else {
                    if try loadPending(id) != nil, !FileManager.default.fileExists(atPath: local(id).appending(path: "set.json").path) {
                        try FileManager.default.removeItem(at: pendingURL(id))
                        bindings[id] = nil
                        continue
                    }
                    throw BackupError.message("找不到此硬盘上的备份集合")
                }
                if let pending = try loadPending(id) {
                    if set.revision >= pending.revision { try finalize(pending, set: set) }
                    else { try FileManager.default.removeItem(at: pendingURL(id)) }
                }
                stores[id] = store
                try await attach(set, to: store)
                if !alreadyOpen {
                    for job in set.mappings where job.enabled { enqueue(job.job, verify: false) }
                }
            } catch {
                stores[id] = nil
                for job in binding.jobs { await engines[job]?.report(error) }
            }
        }
    }

    private func attach(_ set: BackupSet, to store: BackupSetStore) async throws {
        guard var binding = bindings[set.id] else { return }
        let missing = set.mappings.filter { !binding.jobs.contains($0.job) }
        if !missing.isEmpty || binding.mount.path != store.volume.mount.path || sets[set.id] != set {
            binding.mount = store.volume.mount
            binding.jobs.append(contentsOf: missing.map(\.job))
            let jobs = missing.map { makeJob($0, in: set, binding: binding, volume: store.volume, source: nil, automatic: false, eject: false) }
            try finalize(PendingSetup(binding: binding, revision: set.revision, jobs: jobs), set: set)
        }
        await loadEngines(binding)
        for mapping in set.mappings {
            try? await engines[mapping.job]?.bindMember(to: store.volume, relative: BackupSet.target(mapping.folder))
        }
        publish()
    }

    public func previewSetup(volumeRoot: URL, sources: [URL]) throws -> BackupSetupPreview {
        let access = Scope(volumeRoot)
        let volume = try VolumeInfo.inspect(access.url)
        try validateDisk(access, volume: volume)
        let disk = try Tree(volume.mount.resolvingSymlinksInPath())
        let existing = try BackupSetStore.read(disk, volume: volume)
        var rows = (existing?.mappings ?? []).map { mapping in
            BackupSetupRow(id: mapping.id, source: engines[mapping.job]?.presentation.job?.source,
                           name: mapping.name, group: mapping.group, previousFolder: mapping.folder)
        }
        guard !sources.isEmpty else { throw BackupError.message("请选择至少一个源文件夹") }
        var selected: [UUID: (Scope, String)] = [:]
        var paths = rows.compactMap(\.source).filter { !overlaps($0, volume.mount.appending(path: BackupSet.folderName)) }
        let target = volume.mount.appending(path: BackupSet.folderName)
        for source in sources {
            let scope = Scope(source)
            let tree = try Tree(scope.url.resolvingSymlinksInPath())
            let url = tree.url
            guard !paths.contains(where: { overlaps($0, url) }) else {
                throw BackupError.message("已选文件夹包含重复或父子目录：\(url.path)")
            }
            guard !overlaps(url, target), !overlaps(url, root.resolvingSymlinksInPath()),
                  !overlaps(url, volume.mount.appending(path: storageName)) else {
                throw BackupError.message("源文件夹与备份位置重叠：\(url.path)")
            }
            let id = UUID()
            let name = url.lastPathComponent
            rows.append(BackupSetupRow(id: id, source: url, name: name, group: "", previousFolder: nil))
            paths.append(url)
            selected[id] = (scope, try SyncEngine.identity(tree))
        }
        let key: (String) -> String = { pathKey($0, caseSensitive: volume.caseSensitive) }
        let counts = Dictionary(grouping: rows, by: { key($0.name) }).mapValues(\.count)
        let direct = Set(rows.filter { $0.group.isEmpty && counts[key($0.name)] == 1 }.map { key($0.name) })
        var used = Set(rows.filter { !$0.group.isEmpty }.map { key($0.folder) })
        for index in rows.indices where rows[index].group.isEmpty && counts[key(rows[index].name), default: 0] > 1 {
            let row = rows[index]
            let parent = row.source?.deletingLastPathComponent().lastPathComponent ?? ""
            let base = parent.isEmpty || parent == "/" || isBackupControl(parent) ? "来源" : parent
            var group = base
            var suffix = 2
            while direct.contains(key(group)) || used.contains(key(pathJoin(group, row.name))) {
                group = "\(base) \(suffix)"
                suffix += 1
            }
            rows[index].group = group
            used.insert(key(rows[index].folder))
        }
        let preview = BackupSetupPreview(id: UUID(), volume: volume, rows: rows)
        draft = Draft(preview: preview, access: access, current: existing, sources: selected)
        return preview
    }

    private func overlaps(_ lhs: URL, _ rhs: URL) -> Bool {
        relativePath(lhs, in: rhs) != nil || relativePath(rhs, in: lhs) != nil
    }

    private func validateDisk(_ access: Scope, volume: VolumeInfo) throws {
        guard allowInternal || volume.isExternal else { throw BackupError.message("请选择外置备份硬盘") }
        guard access.url.resolvingSymlinksInPath().path == volume.mount.resolvingSymlinksInPath().path,
              !volume.identifier.isEmpty else { throw BackupError.message("请选择备份硬盘的根目录") }
    }

    private func bookmark(_ scope: Scope, readOnly: Bool) throws -> Data? {
        if allowInternal { return try scope.url.bookmarkData(options: .minimalBookmark) }
        let options: URL.BookmarkCreationOptions = readOnly ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess] : .withSecurityScope
        return try scope.url.bookmarkData(options: options)
    }

    public func discardSetup(_ id: UUID) {
        if draft?.preview.id == id { draft = nil }
    }

    @discardableResult
    public func confirmSetup(_ id: UUID, groups: [UUID: String] = [:], automatic: Bool = true,
                             ejectAfterBackup: Bool = true) async throws -> BackupSet {
        try beginOperation()
        defer { endOperation() }
        guard let draft, draft.preview.id == id else { throw BackupError.message("请重新预览备份映射") }
        let volume = try VolumeInfo.inspect(draft.access.url)
        try validateDisk(draft.access, volume: volume)
        guard volume.identifier == draft.preview.volume.identifier else { throw BackupError.message("备份硬盘已更换") }
        var set = draft.current ?? BackupSet(format: volume.format)
        let old = set
        let store = try stores[set.id] ?? BackupSetStore(draft.access, volume: volume, interrupt: interrupt)
        guard try store.recover() == draft.current else { throw BackupError.message("备份映射已改变，请重新预览") }
        var binding = try bindings[set.id] ?? Binding(id: set.id, volumeID: volume.identifier, mount: volume.mount,
                                                    bookmark: bookmark(draft.access, readOnly: false), jobs: [])
        var additions: [Marker] = []
        var moves: [SetMove] = []
        var jobs: [BackupJob] = []
        guard set.revision < Int64.max else { throw BackupError.message("备份集合的代次已满") }
        set.revision += 1
        set.mappings = []
        for row in draft.preview.rows {
            let group = groups[row.id] ?? row.group
            guard group.isEmpty || (try? pathComponents(group).count) == 1,
                  row.group.isEmpty || !group.isEmpty else { throw BackupError.message("请输入有效的来源分组名称") }
            let folder = pathJoin(group, row.name)
            if var mapping = old.mappings.first(where: { $0.id == row.id }) {
                if mapping.folder != folder {
                    try ensureMemberWriter(mapping.job, store: store)
                    moves.append(SetMove(from: mapping.folder, to: folder, job: mapping.job))
                    mapping.folder = folder
                }
                set.mappings.append(mapping)
            } else if let (scope, identity) = draft.sources[row.id], let url = row.source {
                let tree = try Tree(url)
                guard try SyncEngine.identity(tree) == identity else { throw BackupError.message("源文件夹已移动，请重新选择") }
                let mapping = FolderMapping(id: row.id, job: UUID(), folder: folder, enabled: true)
                set.mappings.append(mapping)
                let source = (url, try bookmark(scope, readOnly: true), identity)
                let job = makeJob(mapping, in: set, binding: binding, volume: volume, source: source,
                                  automatic: automatic, eject: ejectAfterBackup)
                additions.append(volume.format == .exfat ?
                    Marker(version: 2, job: job.id, format: .exfat, initialWriter: host, legacyGeneration: 0) :
                    Marker(version: 1, job: job.id, volume: volume.identifier, format: .apfs))
                jobs.append(job)
                binding.jobs.append(job.id)
            }
        }
        try set.validate(on: volume)
        let pending = PendingSetup(binding: binding, revision: set.revision, jobs: jobs)
        try save(pending, to: pendingURL(set.id))
        for move in moves { try await engines[move.job]?.bindMember(to: nil, relative: nil) }
        do {
            try store.apply(SetTransition(base: old.revision, next: set, additions: additions, moves: moves))
            try finalize(pending, set: set)
        } catch {
            bindings[set.id] = bindings[set.id] ?? binding
            stores[set.id] = store
            refreshRequested = true
            throw error
        }
        stores[set.id] = store
        self.draft = nil
        try await attach(set, to: store)
        paused = false
        for job in jobs where job.automatic { enqueue(job.id, verify: false) }
        return set
    }

    private func ensureMemberWriter(_ job: UUID, store: BackupSetStore) throws {
        guard let status = engines[job]?.presentation, status.job?.restoreOnly == false,
              status.progress.state != .takeoverRequired, status.volume != nil else {
            throw BackupError.message("请先在本机接管需要调整位置的备份文件夹")
        }
    }

    private func makeJob(_ mapping: FolderMapping, in set: BackupSet, binding: Binding, volume: VolumeInfo,
                         source: (URL, Data?, String)?, automatic: Bool, eject: Bool) -> BackupJob {
        let relative = BackupSet.target(mapping.folder)
        let target = volume.mount.appending(path: relative, directoryHint: .isDirectory)
        return BackupJob(id: mapping.job, source: source?.0 ?? target, target: target, volumeID: binding.volumeID,
                         volumeName: volume.name, format: volume.format, sourceBookmark: source?.1,
                         targetBookmark: nil, sourceIdentity: source?.2 ?? "", targetRelativePath: relative,
                         automatic: automatic, restoreOnly: source == nil, existingFiles: .updateFromSource,
                         ejectAfterBackup: eject, storageBookmark: binding.bookmark, setID: set.id)
    }

    public func openCollection(on volumeRoot: URL) async throws {
        try beginOperation()
        defer { endOperation() }
        let access = Scope(volumeRoot)
        let volume = try VolumeInfo.inspect(access.url)
        try validateDisk(access, volume: volume)
        let disk = try Tree(volume.mount.resolvingSymlinksInPath())
        let existing = try BackupSetStore.read(disk, volume: volume)
        let store = try existing.flatMap { stores[$0.id] } ?? BackupSetStore(access, volume: volume, interrupt: interrupt)
        guard let set = try store.recover() else { throw BackupError.message("这块硬盘没有 BackupGenius 备份集合") }
        if bindings[set.id] == nil {
            let binding = Binding(id: set.id, volumeID: volume.identifier, mount: volume.mount,
                                  bookmark: try bookmark(access, readOnly: false), jobs: set.mappings.map(\.job))
            let jobs = set.mappings.map { makeJob($0, in: set, binding: binding, volume: volume, source: nil, automatic: false, eject: false) }
            try finalize(PendingSetup(binding: binding, revision: set.revision, jobs: jobs), set: set)
        }
        stores[set.id] = store
        try await attach(set, to: store)
    }

    public func setEnabled(_ enabled: Bool, job id: UUID) async throws {
        try beginOperation()
        defer { endOperation() }
        guard let setID = engines[id]?.presentation.job?.setID, var set = sets[setID], let store = stores[setID],
              let index = set.mappings.firstIndex(where: { $0.job == id }) else { throw BackupError.disconnected }
        try ensureMemberWriter(id, store: store)
        let base = set.revision
        guard base < Int64.max else { throw BackupError.message("备份集合的代次已满") }
        set.revision += 1
        set.mappings[index].enabled = enabled
        try store.apply(SetTransition(base: base, next: set, additions: [], moves: []))
        try await attach(set, to: store)
        if enabled { enqueue(id, verify: false) }
    }

    public func setMedium(_ medium: StorageMedium?, device: StorageDeviceInfo) async throws {
        guard !device.identifier.isEmpty else { return }
        media[device.identifier.uppercased()] = medium
        try save(media, to: mediaURL)
        for engine in allEngines { await engine.setMediumOverrides(media) }
        publish()
    }

    public func setAutomatic(_ enabled: Bool, job id: UUID) async throws {
        guard let engine = engine(for: id) else { return }
        try await engine.setAutomatic(enabled)
        if enabled { enqueue(id, verify: false) }
    }

    public func setEjectAfterBackup(_ enabled: Bool, job id: UUID) async throws {
        guard let selected = engine(for: id), let job = selected.presentation.job else { return }
        if let setID = job.setID, let set = sets[setID] {
            for mapping in set.mappings { try await engines[mapping.job]?.setEjectAfterBackup(enabled) }
        } else {
            try await selected.setEjectAfterBackup(enabled)
        }
    }

    public func restore(_ id: UUID, version: UUID?, to folder: URL) async throws -> URL {
        try beginOperation()
        defer { endOperation() }
        guard let engine = engine(for: id) else { throw BackupError.disconnected }
        return try await engine.restore(version, to: folder)
    }

    public func confirmTakeover(job id: UUID, preview: UUID, choices: [String: TakeoverChoice]) async throws -> BackupJob {
        try beginOperation()
        defer { endOperation() }
        guard let engine = engine(for: id) else { throw BackupError.disconnected }
        let job = try await engine.confirmTakeover(preview, choices: choices)
        enqueue(id, verify: false)
        return job
    }

    private func enqueue(_ id: UUID?, verify: Bool) {
        guard let id = id ?? legacy.presentation.job?.id, !closing,
              let engine = engine(for: id), engine.presentation.job?.automatic == true,
              engine.presentation.job?.restoreOnly == false else { return }
        if let setID = engine.presentation.job?.setID,
           sets[setID]?.mappings.first(where: { $0.job == id })?.enabled != true { return }
        automatic[id] = verify || automatic[id] == true
        scheduleAutomatic()
    }

    private func scheduleAutomatic() {
        guard !automatic.isEmpty, automaticTask == nil, !busy, !paused, !closing else { return }
        automaticTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { await self?.runAutomatic() }
        }
    }

    private func runAutomatic() async {
        automaticTask = nil
        guard !busy, !paused, !closing, let id = automatic.keys.first,
              let job = engine(for: id)?.presentation.job else { return }
        let device = job.volumeID.uppercased()
        let due = automatic.filter { engine(for: $0.key)?.presentation.job?.volumeID.uppercased() == device }
        for key in due.keys { automatic[key] = nil }
        await runDisk(device, verify: false, requested: due)
    }

    public func sync(_ id: UUID, verify: Bool = false) async {
        guard let job = engine(for: id)?.presentation.job else { return }
        await runDisk(job.volumeID.uppercased(), verify: verify, requested: nil)
    }

    private func onDisk(_ id: String) -> [BackupFolderStatus] {
        presentation.folders.filter { $0.job.volumeID.uppercased() == id }
    }

    private func runDisk(_ diskID: String, verify: Bool, requested: [UUID: Bool]?) async {
        guard !busy, !paused, !closing else { return }
        let all = onDisk(diskID).filter { !$0.job.restoreOnly && $0.mapping?.enabled != false }
        let eligible = all.filter { requested == nil || $0.job.automatic }
        guard !eligible.isEmpty, eligible.contains(where: { $0.snapshot.volume != nil }) else { scheduleAutomatic(); return }
        for folder in eligible { automatic[folder.id] = nil }
        busy = true
        defer { endOperation() }
        var summary = SyncProgress(state: .checking)
        var success = true
        var ejectionRequested = false
        let begin = Date()
        for folder in eligible {
            if paused || closing { break }
            guard let engine = engine(for: folder.id) else { continue }
            running = folder.id
            diskProgress[diskID] = summary
            publish()
            do {
                try await alignFolderName(folder, engine: engine)
                let result = try await (verify || requested?[folder.id] == true ? engine.verify() : engine.syncNow())
                summary.add(result)
                success = success && result.state == .upToDate
                if result.state != .upToDate, summary.message == nil { summary.message = result.message ?? "有备份文件夹需要处理" }
                ejectionRequested = ejectionRequested || folder.job.ejectAfterBackup == true
            } catch {
                success = false
                summary.message = error.localizedDescription
                summary.issueCount += 1
                await engine.report(error)
            }
        }
        running = nil
        summary.state = paused ? .paused : (success ? .upToDate : .needsAttention)
        summary.elapsedSeconds = Date().timeIntervalSince(begin)
        summary.lastSuccess = success && !paused ? Date() : diskProgress[diskID]?.lastSuccess
        diskProgress[diskID] = summary
        if success && !paused && ejectionRequested && eligible.count == all.count {
            do {
                var pending = false
                for folder in eligible {
                    if try await engine(for: folder.id)?.hasPendingChanges() == true {
                        if folder.job.automatic { automatic[folder.id] = false }
                        pending = true
                    }
                }
                if !pending && !automatic.keys.contains(where: { key in eligible.contains(where: { $0.id == key }) }) {
                    try await ejectDisk(diskID)
                }
            } catch {
                diskProgress[diskID]?.message = "备份已完成。\(error.localizedDescription)"
            }
        }
    }

    private func alignFolderName(_ status: BackupFolderStatus, engine: SyncEngine) async throws {
        guard let id = status.job.setID, let store = stores[id], var set = sets[id],
              let index = set.mappings.firstIndex(where: { $0.job == status.id }),
              engine.presentation.progress.state != .takeoverRequired else { return }
        let source = try await engine.memberSource()
        let mapping = set.mappings[index]
        let folder = pathJoin(mapping.group, source.lastPathComponent)
        if folder == mapping.folder {
            if source != status.job.source { try await engine.bindMember(to: store.volume, relative: nil, source: source) }
            return
        }
        let base = set.revision
        guard base < Int64.max else { throw BackupError.message("备份集合的代次已满") }
        set.revision += 1
        set.mappings[index].folder = folder
        try set.validate(on: store.volume)
        try await engine.bindMember(to: nil, relative: nil)
        do {
            try store.apply(SetTransition(base: base, next: set, additions: [],
                                          moves: [SetMove(from: mapping.folder, to: folder, job: mapping.job)]))
            try await attach(set, to: store)
            try await engine.bindMember(to: store.volume, relative: BackupSet.target(folder), source: source)
        } catch {
            refreshRequested = true
            throw error
        }
    }

    public func pause() {
        paused = true
        for engine in allEngines { engine.pause() }
        publish()
    }

    public func resume(_ id: UUID) async {
        paused = false
        for engine in allEngines { engine.resume() }
        if !busy { await sync(id) }
        scheduleAutomatic()
    }

    public func eject(_ id: UUID) async throws {
        guard let job = engine(for: id)?.presentation.job else { throw BackupError.disconnected }
        if busy {
            pause()
            await withCheckedContinuation { waiters.append($0) }
        }
        try beginOperation()
        defer { endOperation() }
        try await ejectDisk(job.volumeID.uppercased())
        paused = false
    }

    private func ejectDisk(_ id: String) async throws {
        let members = onDisk(id)
        guard let volume = members.compactMap(\.snapshot.volume).first else { throw BackupError.disconnected }
        let eject = try prepareEjection(volume.mount)
        let setIDs = Set(members.compactMap(\.job.setID))
        var released: [SyncEngine] = []
        do {
            for member in members {
                if let engine = engine(for: member.id) {
                    try await engine.releaseForEjection()
                    released.append(engine)
                }
            }
            for set in setIDs { stores[set] = nil }
            try await eject()
            ejectedVolumes.insert(id)
            diskProgress[id]?.state = .ejected
            for engine in released { await engine.didEject(nil) }
        } catch {
            for engine in released { await engine.didEject(error.localizedDescription) }
            refreshRequested = true
            throw error
        }
    }

    public func finishAndClose() async {
        closing = true
        automaticTask?.cancel()
        progressTask?.cancel()
        pause()
        if busy { await withCheckedContinuation { waiters.append($0) } }
        for engine in allEngines { await engine.finishAndClose() }
        stores.removeAll()
        for observer in observers { observer.cancel() }
    }
}

private extension SyncProgress {
    mutating func add(_ result: SyncProgress) {
        examined += result.examined
        planned += result.planned
        processed += result.processed
        skipped += result.skipped
        trackedFiles += result.trackedFiles
        unmanaged += result.unmanaged
        issueCount += result.issueCount
        sourceReadBytes += result.sourceReadBytes
        targetReadBytes += result.targetReadBytes
        latestWrittenBytes += result.latestWrittenBytes
        historyWrittenBytes += result.historyWrittenBytes
        sourceReadRequests += result.sourceReadRequests
        targetReadRequests += result.targetReadRequests
        latestWriteRequests += result.latestWriteRequests
        ioBufferBudget = max(ioBufferBudget, result.ioBufferBudget)
    }
}
