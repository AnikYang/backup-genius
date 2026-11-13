import Foundation
import Darwin

let journalPath = "\(controlName)/journal"
let stagePath = "\(controlName)/stage"
let packPath = "\(controlName)/packs"
let clonePath = "\(controlName)/versions"
private let markerPath = "\(controlName)/job.json"
private let lockPath = "\(controlName)/lock"
private let pendingPath = "\(journalPath)/pending.json"

func staged(_ id: UUID) -> String { pathJoin(stagePath, id.uuidString) }
func packed(_ id: UUID) -> String { pathJoin(packPath, id.uuidString) }
func cloned(_ id: UUID) -> String { pathJoin(clonePath, id.uuidString) }

final class Repository {
    private(set) var tree: Tree
    private(set) var volume: VolumeInfo
    let catalog: Catalog
    private let lock: FD
    private(set) var descriptor: Marker
    let host: UUID
    var ioProfile = IOProfile(source: .unknown, target: .unknown)
    private let interruption: (@Sendable (InterruptionPoint) throws -> Void)?

    static func enroll(_ tree: Tree, volume: VolumeInfo, sourceIdentity: String, source: URL, host: UUID,
                       disk: Tree? = nil) throws -> Marker {
        if try tree.entry(controlName) != nil || tree.entry(identityName) != nil {
            let folder = try locatedTree(tree, volume: volume, disk: disk)
            let marker = try Self.marker(folder, volume: volume)
            guard marker.portable || marker.sourceIdentity == sourceIdentity else {
                throw BackupError.message("此备份绑定了另一源文件夹。可以打开已有备份进行恢复。")
            }
            return marker
        }
        let marker = volume.format == .exfat
            ? Marker(version: 2, job: UUID(), format: volume.format, initialWriter: host, legacyGeneration: 0)
            : Marker(version: 1, job: UUID(), volume: volume.identifier, format: volume.format,
                     sourceIdentity: sourceIdentity, sourcePath: source.path)
        if let disk {
            _ = try relativeLocation(tree, on: disk)
            let store = storagePath(marker.job)
            try disk.mkdir(storageName, existing: true)
            try disk.mkdir(store)
            do {
                let control = try disk.subtree(store)
                let located = try Tree(tree.url, controlTree: control)
                try initialize(located, marker: marker)
                try disk.directory(storageName).flush(directory: true)
                try disk.root.flush(directory: true)
                try publishIdentity(marker, on: located)
            } catch {
                if (try? tree.entry(identityName)) == nil { try? disk.removeOwnedTree(store) }
                throw error
            }
        } else {
            try tree.mkdir(controlName)
            try initialize(tree, marker: marker)
        }
        return marker
    }

    private static func initialize(_ tree: Tree, marker: Marker) throws {
        for dir in [journalPath, stagePath, packPath, clonePath] { try tree.mkdir(dir) }
        try tree.writeDocument(marker, at: markerPath)
        try tree.root.flush(directory: true)
    }

    static func initializeMember(on disk: Tree, folder: String, marker: Marker, volume: VolumeInfo) throws {
        let location = storagePath(marker.job)
        try disk.mkdir(location, existing: true)
        let target = try disk.subtree(folder)
        let tree = try Tree(target.url, controlTree: disk.subtree(location))
        for dir in [journalPath, stagePath, packPath, clonePath] { try tree.mkdir(dir, existing: true) }
        if try tree.entry(markerPath) == nil {
            try tree.writeDocument(marker, at: markerPath)
        }
        guard try Self.marker(tree, volume: volume).job == marker.job else {
            throw BackupError.message("备份文件夹与记录不符")
        }
        try tree.directory(controlName).flush(directory: true)
        try disk.directory(storageName).flush(directory: true)
    }

    static func memberTree(on disk: Tree, folder: String, job: UUID, volume: VolumeInfo) throws -> Tree {
        let target = try disk.subtree(folder)
        let control = try disk.subtree(storagePath(job))
        let tree = try Tree(target.url, controlTree: control)
        guard try marker(tree, volume: volume).job == job else {
            throw BackupError.message("备份文件夹与记录不符")
        }
        return tree
    }

    static func jobID(_ tree: Tree, volume: VolumeInfo) throws -> UUID {
        if try tree.entry(controlName) != nil { return try marker(tree, volume: volume).job }
        return try readIdentity(tree, format: volume.format).job
    }

    static func locatedTree(_ tree: Tree, volume: VolumeInfo, disk: Tree?) throws -> Tree {
        let legacy = try tree.entry(controlName) != nil
        guard try tree.entry(identityName) != nil else { return tree }
        let identity: BackupIdentity
        do { identity = try readIdentity(tree, format: volume.format) }
        catch {
            // A legacy backup may contain a user file with this newer name.
            if legacy { return tree }
            throw error
        }
        guard let disk else { throw BackupError.message("请在设置中选择备份硬盘根目录，授权访问备份记录") }
        _ = try relativeLocation(tree, on: disk)
        let path = storagePath(identity.job)
        if try disk.entry(path) == nil, legacy {
            guard try marker(tree, volume: volume).job == identity.job else {
                throw BackupError.message("备份识别文件与原有记录不符")
            }
            return tree
        }
        guard !legacy else { throw BackupError.message("发现两套备份记录，请检查硬盘") }
        let control = try disk.subtree(path)
        let located = try Tree(tree.url, controlTree: control)
        guard try marker(located, volume: volume).job == identity.job else {
            throw BackupError.message("备份识别文件与原有记录不符")
        }
        return located
    }

    private static func readIdentity(_ tree: Tree, format: DiskFormat) throws -> BackupIdentity {
        let identity = try tree.readDocument(BackupIdentity.self, from: identityName)
        let relative = try VolumeLocation(tree.root).relative(tree.url)
        let sameFolder = format == .exfat
            ? pathKey(identity.folder, caseSensitive: false) == pathKey(relative, caseSensitive: false)
            : identity.folder == relative
        guard identity.layout == 1, identity.format == format, sameFolder else {
            throw BackupError.message("备份识别文件格式无效")
        }
        return identity
    }

    static func checkIdentitySlot(_ tree: Tree, job: UUID, format: DiskFormat) throws {
        if try tree.entry(identityName) != nil {
            guard (try? readIdentity(tree, format: format).job) == job else {
                throw BackupError.message("备份目录已包含同名文件 \(identityName)")
            }
        } else if try tree.entry(identitySidecarName) != nil {
            throw BackupError.message("备份目录已包含同名文件 \(identitySidecarName)")
        }
    }

    private static func publishIdentity(_ marker: Marker, on tree: Tree) throws {
        try checkIdentitySlot(tree, job: marker.job, format: marker.format)
        guard try tree.entry(identityName) == nil else { return }
        let relative = try VolumeLocation(tree.root).relative(tree.url)
        let identity = BackupIdentity(layout: 1, job: marker.job, format: marker.format, folder: relative)
        try tree.writeDocument(identity, at: identityName, stagingIn: stagePath, hidden: true)
    }

    private static func storagePath(_ id: UUID) -> String { pathJoin(storageName, id.uuidString) }

    private static func relativeLocation(_ tree: Tree, on disk: Tree) throws -> String {
        let location = try VolumeLocation(tree.root)
        guard disk.device == tree.device, disk.url.path == location.mount.resolvingSymlinksInPath().path else {
            throw BackupError.message("请选择此备份硬盘的根目录")
        }
        let relative = try location.relative(tree.url)
        guard !relative.isEmpty, relative.split(separator: "/").first?.lowercased() != storageName else {
            throw BackupError.message("请选择硬盘内的一个普通文件夹作为备份位置")
        }
        return relative
    }

    static func marker(_ tree: Tree, volume: VolumeInfo) throws -> Marker {
        let marker = try tree.readDocument(Marker.self, from: markerPath)
        try check(marker, volume: volume)
        return marker
    }

    private static func check(_ marker: Marker, volume: VolumeInfo) throws {
        let legacy = marker.version == 1 && (marker.volume == "" || marker.volume == volume.identifier)
        let portable = marker.portable && volume.format == .exfat && (marker.legacyGeneration ?? -1) >= 0
        guard marker.format == volume.format, legacy || portable else {
            throw BackupError.message("此硬盘与原备份标识不符")
        }
    }

    init(tree: Tree, volume: VolumeInfo, job: BackupJob, catalog: Catalog, host: UUID,
         interruption: (@Sendable (InterruptionPoint) throws -> Void)?) throws {
        self.tree = tree
        self.volume = volume
        self.catalog = catalog
        self.host = host
        self.interruption = interruption
        descriptor = try Self.marker(tree, volume: volume)
        do {
            lock = try tree.createFile(lockPath)
        } catch BackupError.io(_, _, let code) where code == EEXIST {
            lock = try tree.file(lockPath, writable: true)
        }
        guard flock(lock.value, LOCK_EX | LOCK_NB) == 0 else {
            throw BackupError.message("此备份正在另一个进程中使用")
        }
        descriptor = try Self.marker(tree, volume: volume)
        guard descriptor.job == job.id else { throw BackupError.message("此文件夹属于另一项备份") }
    }

    var rich: Bool { volume.format == .apfs }

    func updateVolume(_ info: VolumeInfo) { volume = info }

    func organize(on disk: Tree) throws {
        guard tree.controlTree == nil else { return }
        try tree.checkRoot()
        try disk.checkRoot()
        guard try !needsRecovery() else { throw BackupError.message("请先恢复未完成的备份") }
        let relative = try Self.relativeLocation(tree, on: disk)
        let store = Self.storagePath(descriptor.job)
        try disk.mkdir(storageName, existing: true)
        guard try disk.entry(store) == nil else { throw BackupError.message("备份记录位置已被占用") }
        // Publish the pointer first. Until the rename succeeds, the same job can
        // still be read from its original directory with the same file lock.
        try Self.publishIdentity(descriptor, on: tree)
        try disk.rename(pathJoin(relative, controlName), to: store)
        try disk.directory(storageName).flush(directory: true)
        try disk.root.flush(directory: true)
        try tree.root.flush(directory: true)
        tree = try Self.locatedTree(tree, volume: volume, disk: disk)
    }

    var owner: UUID? {
        get throws { try catalog.get("writer").flatMap(UUID.init(uuidString:)) ?? descriptor.initialWriter }
    }

    func upgrade(owner: UUID?) throws {
        guard descriptor.version == 1, volume.format == .exfat else { return }
        guard try !needsRecovery() else { throw BackupError.message("请先恢复旧版备份的未完成事务") }
        let marker = Marker(version: 2, job: descriptor.job, format: .exfat, initialWriter: owner,
                            legacyGeneration: try catalog.generation)
        try tree.writeDocument(marker, at: markerPath, replacing: true)
        descriptor = marker
    }

    func claim() throws {
        var batch = try newBatch()
        batch.takeover = true
        batch.writer = host
        try commit(batch, patches: [:], beforeApply: {})
    }

    func refreshCapacity() {
        var info = statfs()
        guard fstatfs(tree.root.value, &info) == 0 else { return }
        let block = Int64(info.f_bsize)
        volume = VolumeInfo(name: volume.name, mount: volume.mount, identifier: volume.identifier, format: volume.format,
                            availableBytes: Int64(info.f_bavail) * block, totalBytes: Int64(info.f_blocks) * block,
                            caseSensitive: volume.caseSensitive, isExternal: volume.isExternal, device: volume.device)
    }

    private func commitPath(_ sequence: Int64) -> String {
        pathJoin(journalPath, String(format: "%020lld.json", sequence))
    }

    private func readBatch(_ path: String) throws -> DiskBatch {
        let batch = try tree.readDocument(Envelope.self, from: path).batch()
        let portable = descriptor.portable && batch.generation > (descriptor.legacyGeneration ?? 0)
        guard portable == (batch.version == 2), !portable || batch.writer != nil || batch.edits.allSatisfy({ $0.method == .archive }) else {
            throw BackupError.message("备份记录与协议版本不符")
        }
        if batch.takeover == true {
            guard portable, batch.writer != nil, batch.edits.isEmpty, batch.chunks.isEmpty,
                  batch.pruned.isEmpty, batch.retiredPacks.isEmpty else { throw BackupError.message("接管记录无效") }
        }
        for edit in batch.edits {
            try userPath(edit.path)
            if let from = edit.from { try userPath(from) }
            if let next = edit.next, next.path != edit.path {
                throw BackupError.message("备份记录的文件路径不一致")
            }
            if let archive = edit.archive { try userPath(archive.item.path) }
            if portable {
                if let next = edit.next { try checkRecipe(kind: next.source.kind, size: next.source.size, hashes: next.hashes) }
                if let archive = edit.archive {
                    guard archive.clone == nil else { throw BackupError.message("exFAT 历史记录包含克隆文件") }
                    try checkRecipe(kind: archive.kind, size: archive.item.size, hashes: archive.hashes)
                }
            }
            if edit.rollbackBlocks.contains(where: { $0 < 0 || Int64($0) > Int64.max / Int64(blockSize) }) {
                throw BackupError.message("恢复记录的块范围无效")
            }
        }
        for chunk in batch.chunks {
            guard chunk.hash.count == digestSize, chunk.length > 0, chunk.length <= blockSize,
                  chunk.offset >= 0, chunk.offset <= Int64.max - Int64(chunk.length) else {
                throw BackupError.message("历史数据的块范围无效")
            }
        }
        return batch
    }

    private func checkRecipe(kind: EntryKind, size: Int64, hashes: Data) throws {
        guard size >= 0, hashes.count % digestSize == 0 else { throw BackupError.message("备份块清单无效") }
        let count = kind == .regular ? size / Int64(blockSize) + (size % Int64(blockSize) == 0 ? 0 : 1) : 0
        guard count == Int64(hashes.count / digestSize) else { throw BackupError.message("备份块清单与文件大小不符") }
    }

    func needsRecovery() throws -> Bool { try tree.entry(pendingPath) != nil }

    @discardableResult
    func open() throws -> Bool {
        try tree.checkRoot()
        let names = try tree.names(in: journalPath).filter {
            $0.count == 25 && $0.hasSuffix(".json") && Int64($0.prefix(20)) != nil
        }.sorted()
        let latest = try catalog.generation
        guard (descriptor.legacyGeneration ?? 0) <= Int64(names.count) else { throw BackupError.message("旧版提交记录不完整") }
        guard latest <= Int64(names.count) else { throw BackupError.message("硬盘上的提交记录不完整") }
        if latest > 0 {
            let persisted = try readBatch(commitPath(latest))
            guard persisted.id.uuidString == (try catalog.get("lastBatch")) else {
                throw BackupError.message("硬盘上的提交记录已改变")
            }
        }
        for index in Int(latest)..<names.count {
            let generation = Int64(index + 1)
            let batch = try readBatch(pathJoin(journalPath, names[index]))
            guard batch.generation == generation, pathName(commitPath(generation)) == names[index] else {
                throw BackupError.message("硬盘上的提交记录不连续")
            }
            if batch.version == 2, batch.takeover != true, try batch.writer != owner {
                throw BackupError.message("备份写入者与接管记录不符")
            }
            let align = try batch.writer == host && batch.takeover != true && catalog.get("aligned.source") != nil
            try catalog.apply(batch, caseSensitive: volume.caseSensitive, align: align)
        }
        let recovered = try recover()
        for name in try tree.names(in: stagePath) where !name.hasPrefix("._") {
            try tree.removeOwnedTree(pathJoin(stagePath, name))
        }
        for name in try tree.names(in: journalPath) where name.hasPrefix(".write-") {
            try tree.remove(pathJoin(journalPath, name))
        }
        try removeOrphans()
        return recovered
    }

    private func recover() throws -> Bool {
        guard try needsRecovery() else { return false }
        let batch = try readBatch(pendingPath)
        try protectIdentity(in: batch)
        let generation = try catalog.generation
        if batch.generation == generation, batch.id.uuidString == (try catalog.get("lastBatch")) {
            try clearPending()
            return false
        }
        guard batch.generation == generation + 1 else { throw BackupError.message("待恢复的提交记录顺序异常") }
        if batch.version == 2, batch.takeover != true, try batch.writer != owner {
            throw BackupError.message("待恢复的记录与接管状态不符")
        }
        let newChunks = Dictionary(batch.chunks.map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first })
        for edit in batch.edits.reversed() {
            try rollback(edit, chunks: newChunks, portable: batch.version == 2)
        }
        try flushParents(batch.edits)
        try clearPending()
        return true
    }

    private func clearPending() throws {
        try tree.remove(pendingPath)
        try tree.directory(journalPath).flush(directory: true)
    }

    func newBatch() throws -> DiskBatch {
        DiskBatch(id: UUID(), generation: try catalog.generation + 1)
    }

    func commit(_ input: DiskBatch, patches: [String: PatchData], onWrite: ((Int) -> Void)? = nil,
                beforeApply: () throws -> Void) throws {
        var batch = input
        guard !batch.edits.isEmpty || !batch.pruned.isEmpty || !batch.retiredPacks.isEmpty || batch.takeover == true else { return }
        try protectIdentity(in: batch)
        try tree.checkRoot()
        guard try !needsRecovery() else { throw BackupError.message("需要先恢复上一次同步") }
        let generation = try catalog.generation
        guard batch.generation == generation + 1 else { throw BackupError.message("备份记录已变更，请重新检查") }
        if descriptor.portable {
            let owner = try owner
            let archiveOnly = !batch.edits.isEmpty && batch.edits.allSatisfy { $0.method == .archive }
            guard owner == host || batch.takeover == true || archiveOnly else { throw BackupError.message("请先接管此备份") }
            if generation > 0 {
                let head = try readBatch(commitPath(generation))
                guard head.id.uuidString == (try catalog.get("lastBatch")) else { throw BackupError.message("提交记录已变更") }
            }
            batch.version = 2
            batch.writer = batch.takeover == true ? host : owner
            for i in batch.edits.indices {
                if var next = batch.edits[i].next {
                    next.portableID = try next.portableID ?? catalog.file(batch.edits[i].from ?? next.path)?.portableID ?? UUID()
                    batch.edits[i].next = next
                }
            }
        }
        try beforeApply()
        try tree.directory(stagePath).flush(directory: true)
        try tree.writeDocument(try envelope(batch), at: pendingPath)
        try interruption?(.prepared)

        var attempted = 0
        do {
            for index in batch.edits.indices {
                let edit = batch.edits[index]
                if edit.method != .archive && (edit.method != .record || edit.before != nil) {
                    try requireBefore(edit, path: edit.from ?? edit.path)
                }
                attempted += 1
                let patch = patches[batch.edits[index].path]
                try apply(&batch.edits[index], patch: patch, onWrite: onWrite)
            }
            try flushParents(batch.edits)
            try interruption?(.applied)
        } catch BackupError.injected {
            throw BackupError.injected
        } catch {
            // A real I/O failure may also prevent rollback. The prepared record stays on disk.
            try? rollBackAttempted(batch, count: attempted)
            throw error
        }

        // Keep the prepared record until an independent, checksummed commit is durable.
        try tree.writeDocument(try envelope(batch), at: commitPath(batch.generation))
        try interruption?(.committed)
        let align = try batch.writer == host && batch.takeover != true && catalog.get("aligned.source") != nil
        try catalog.apply(batch, caseSensitive: volume.caseSensitive, align: align)
        try clearPending()
    }

    private func protectIdentity(in batch: DiskBatch) throws {
        guard tree.controlTree != nil else { return }
        for edit in batch.edits where isBackupControl(edit.path) || edit.from.map(isBackupControl) == true {
            throw BackupError.message("备份记录尝试更改保留路径：\(edit.path)")
        }
    }

    private func envelope(_ batch: DiskBatch) throws -> Envelope {
        guard batch.version == 2 else { return try Envelope(batch) }
        var portable = batch
        for i in portable.edits.indices {
            portable.edits[i].before = portable.edits[i].before?.portable
            if var next = batch.edits[i].next {
                next.source = next.source.portable
                next.target = next.target?.portable
                portable.edits[i].next = next
            }
        }
        return try Envelope(portable)
    }

    private func rollBackAttempted(_ batch: DiskBatch, count: Int) throws {
        try tree.checkRoot()
        let chunks = Dictionary(batch.chunks.map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first })
        let edits = Array(batch.edits.prefix(count))
        for edit in edits.reversed() { try rollback(edit, chunks: chunks, portable: batch.version == 2) }
        try flushParents(edits)
        try clearPending()
    }

    private func requireBefore(_ edit: DiskEdit, path: String) throws {
        let current = try tree.entry(path)
        if let before = edit.before {
            guard let current,
                  (before.kind == .directory ? before.identity == current.identity : before == current) else {
                throw BackupError.unstable(path)
            }
        } else if current != nil {
            throw BackupError.message("目标位置已有其他文件：\(path)")
        }
    }

    private func apply(_ edit: inout DiskEdit, patch: PatchData?, onWrite: ((Int) -> Void)?) throws {
        switch edit.method {
        case .record, .archive:
            return
        case .install:
            guard let staging = edit.staging else { throw BackupError.message("缺少待发布文件") }
            try tree.rename(staged(staging), to: edit.path, replacing: edit.before != nil)
        case .patch:
            guard let next = edit.next, let patch else { throw BackupError.message("缺少增量数据") }
            let file = try tree.file(edit.path, writable: true)
            guard try file.stamp() == edit.before else { throw BackupError.unstable(edit.path) }
            if let interruption {
                try patch.apply(to: file, window: ioProfile.targetWindow, onWrite: onWrite) { try interruption(.firstBlock) }
            } else {
                try patch.apply(to: file, window: ioProfile.targetWindow, onWrite: onWrite)
            }
            try file.resize(next.source.size)
            try file.apply(next.attributes, rich: false)
            try file.flush()
        case .attributes:
            guard let attrs = edit.next?.attributes, let before = edit.before else {
                throw BackupError.message("缺少文件属性")
            }
            try setAttributes(attrs, at: edit.path, kind: before.kind)
        case .remove:
            if let before = edit.before {
                try tree.remove(edit.path, directory: before.kind == .directory, keepNonEmpty: true)
            }
        case .move, .caseMove:
            guard let from = edit.from, let staging = edit.staging else { throw BackupError.message("缺少移动记录") }
            if edit.method == .caseMove {
                try tree.rename(from, to: staged(staging))
                try tree.rename(staged(staging), to: edit.path)
            } else {
                try tree.rename(from, to: edit.path)
            }
        }
        if var next = edit.next {
            next.target = try tree.entry(edit.path)
            edit.next = next
        }
    }

    private func flushParents(_ edits: [DiskEdit]) throws {
        var paths: Set<String> = [stagePath]
        for edit in edits where edit.method != .record && edit.method != .archive {
            paths.insert(pathParent(edit.path))
            if let from = edit.from { paths.insert(pathParent(from)) }
        }
        for path in paths {
            if try tree.entry(path)?.kind == .directory {
                try tree.directory(path).flush(directory: true)
            }
        }
    }

    func setAttributes(_ attrs: MacAttributes, at path: String, kind: EntryKind) throws {
        switch kind {
        case .regular:
            let file = try tree.file(path)
            try file.apply(attrs, rich: rich)
            try file.flush()
        case .directory:
            let directory = try tree.directory(path)
            var writable = attrs
            writable.mode |= 0o700
            try directory.apply(writable, rich: rich)
            try directory.flush(directory: true)
        case .symlink:
            try tree.applyLinkTime(attrs, at: path)
        case .unsupported:
            throw BackupError.message("不支持的文件类型：\(path)")
        }
    }

    private func rollback(_ edit: DiskEdit, chunks: [Data: ChunkLocation], portable: Bool = false) throws {
        if edit.method == .record || edit.method == .archive { return }
        let current = try tree.entry(edit.path)
        switch edit.method {
        case .record, .archive:
            return
        case .move, .caseMove:
            guard let from = edit.from, let staging = edit.staging else {
                throw BackupError.message("无法恢复移动记录")
            }
            if try tree.entry(staged(staging)) != nil {
                try tree.rename(staged(staging), to: from)
            } else if edit.method == .caseMove {
                let names = try tree.names(in: pathParent(edit.path))
                if names.contains(pathName(edit.path)), !names.contains(pathName(from)) {
                    try tree.rename(edit.path, to: staged(staging))
                    try tree.rename(staged(staging), to: from)
                }
            } else if try tree.entry(from) == nil, let current, let before = edit.before {
                let matches = try portable && edit.next.map { try matchesInstalled($0, current: current, at: edit.path) } == true
                guard matches ||
                        current.matchesTarget(before, format: volume.format) ||
                        (current.identity == before.identity && current.sameContentIdentity(as: before)) else {
                    throw BackupError.message("移动中的文件已在其他程序中更改：\(edit.path)")
                }
                try tree.rename(edit.path, to: from)
            }
        case .attributes:
            if let current, let attrs = edit.originalAttributes, let before = edit.before, before != current {
                let matches = portable ? try edit.next.map { try matchesInstalled($0, current: current, at: edit.path) } == true : before.identity == current.identity
                guard before.kind == current.kind, matches else {
                    throw BackupError.message("待恢复的文件已被替换：\(edit.path)")
                }
                try setAttributes(attrs, at: edit.path, kind: current.kind)
            }
        case .patch:
            guard let version = edit.archive, let next = edit.next, let before = edit.before else {
                throw BackupError.message("缺少文件恢复数据")
            }
            if let current {
                guard current.kind == .regular else { throw BackupError.message("恢复位置已被占用：\(edit.path)") }
                if portable {
                    guard (min(before.size, next.source.size)...max(before.size, next.source.size)).contains(current.size) else {
                        throw BackupError.message("中断后文件已在其他程序中改写：\(edit.path)")
                    }
                    // A prepared edit may never have started. Verify the
                    // preimage before requiring write access to an intact file.
                    let input = try tree.file(edit.path)
                    guard try input.stamp() == current else { throw BackupError.unstable(edit.path) }
                    var intact = current.size == before.size && current.modified == before.modified
                    var offset: Int64 = 0
                    while offset < current.size {
                        let bytes = try input.readExact(at: offset, length: Int(min(Int64(blockSize), current.size - offset)))
                        let hash = digest(bytes)
                        let index = Int(offset / Int64(blockSize))
                        let oldHash = version.hashes.blockHash(index)
                        guard hash == oldHash || hash == next.hashes.blockHash(index) else {
                            throw BackupError.message("待恢复的文件含有未知内容：\(edit.path)")
                        }
                        intact = intact && hash == oldHash
                        offset += Int64(bytes.count)
                    }
                    guard try input.stamp() == current, try tree.entry(edit.path) == current else {
                        throw BackupError.unstable(edit.path)
                    }
                    if intact { return }
                }
                let file = try tree.file(edit.path, writable: true)
                guard try file.stamp() == current else { throw BackupError.unstable(edit.path) }
                let trim = next.source.size < before.size ? Int(next.source.size / Int64(blockSize)) : Int.max
                for index in edit.rollbackBlocks where index < trim {
                    if let hash = version.hashes.blockHash(index) {
                        try file.write(readChunk(hash, additional: chunks), at: Int64(index) * Int64(blockSize))
                    }
                }
                if trim < version.hashes.count / digestSize {
                    for index in trim..<(version.hashes.count / digestSize) {
                        let hash = version.hashes.blockHash(index)!
                        try file.write(readChunk(hash, additional: chunks), at: Int64(index) * Int64(blockSize))
                    }
                }
                try file.resize(before.size)
                try file.apply(version.attributes, rich: false)
                try file.flush(full: true)
            } else {
                try replaceWithArchive(version, at: edit.path, current: nil, additional: chunks)
            }
        case .install, .remove:
            if let before = edit.before {
                if current == before || (before.kind == .directory && current?.identity == before.identity) { return }
                guard let archive = edit.archive else { throw BackupError.message("缺少旧版恢复记录：\(edit.path)") }
                if portable, let current, try matchesArchive(archive, current: current, at: edit.path) { return }
                if portable, let current, edit.method == .install {
                    guard let next = edit.next, try matchesInstalled(next, current: current) else {
                        throw BackupError.message("恢复位置已被其他程序改写：\(edit.path)")
                    }
                }
                if current != nil, edit.method == .remove {
                    throw BackupError.message("恢复位置已有其他文件：\(edit.path)")
                }
                try replaceWithArchive(archive, at: edit.path, current: current, additional: chunks)
            } else if edit.method == .install, let current, let staging = edit.staging, let next = edit.next,
                      try tree.entry(staged(staging)) == nil {
                guard try matchesInstalled(next, current: current) else {
                    throw BackupError.message("恢复位置已有其他文件：\(edit.path)")
                }
                try tree.remove(edit.path, directory: current.kind == .directory, keepNonEmpty: true)
            }
        }
    }

    private func matchesInstalled(_ record: FileRecord, current: FileStamp, at path: String? = nil) throws -> Bool {
        guard record.source.kind == current.kind else { return false }
        if rich, record.target?.identity == current.identity { return true }
        switch current.kind {
        case .regular:
            guard record.source.size == current.size else { return false }
            return try tree.file(path ?? record.path).fileHashes(size: current.size) == record.hashes
        case .symlink:
            return try tree.readLink(path ?? record.path) == record.link
        case .directory:
            return try tree.names(in: path ?? record.path).isEmpty
        case .unsupported:
            return false
        }
    }

    private func matchesArchive(_ version: ArchivedVersion, current: FileStamp, at path: String) throws -> Bool {
        guard version.kind == current.kind else { return false }
        switch current.kind {
        case .regular:
            return try current.size == version.item.size && tree.file(path).fileHashes(size: current.size) == version.hashes
        case .directory: return true
        case .symlink: return try tree.readLink(path) == version.link
        case .unsupported: return false
        }
    }

    private func replaceWithArchive(_ archive: ArchivedVersion, at path: String, current: FileStamp?,
                                    additional: [Data: ChunkLocation]) throws {
        let temp = staged(UUID())
        defer { try? tree.removeOwnedTree(temp) }
        try materialize(archive, on: tree, at: temp, rich: rich, additional: additional, allowClone: rich)
        try tree.rename(temp, to: path, replacing: current != nil)
    }

    func readChunk(_ hash: Data, additional: [Data: ChunkLocation] = [:]) throws -> Data {
        guard let location = try additional[hash] ?? catalog.chunk(hash) else {
            throw BackupError.message("历史数据缺少所需的块")
        }
        return try readChunk(location)
    }

    func readChunk(_ location: ChunkLocation) throws -> Data {
        let file = try tree.file(packed(location.pack))
        let bytes = try file.readExact(at: location.offset, length: location.length)
        guard digest(bytes) == location.hash else { throw BackupError.message("历史数据校验失败") }
        return bytes
    }

    func materialize(_ version: ArchivedVersion, on target: Tree, at path: String, rich: Bool,
                     additional: [Data: ChunkLocation] = [:], allowClone: Bool = false) throws {
        switch version.kind {
        case .regular:
            if let clone = version.clone {
                let file = try tree.file(cloned(clone))
                if allowClone {
                    try target.clone(file, to: path)
                } else {
                    let out = try target.createFile(path)
                    try copyVerified(file, to: out, length: version.item.size, hashes: version.hashes)
                    try out.apply(version.attributes, rich: rich)
                    try out.flush()
                }
            } else {
                let out = try target.createFile(path)
                var offset: Int64 = 0
                for index in 0..<(version.hashes.count / digestSize) {
                    let data = try readChunk(version.hashes.blockHash(index)!, additional: additional)
                    try out.write(data, at: offset)
                    offset += Int64(data.count)
                }
                guard offset == version.item.size else { throw BackupError.message("历史文件大小校验失败") }
                try out.apply(version.attributes, rich: rich)
                try out.flush()
            }
        case .directory:
            try target.mkdir(path)
            try target.directory(path).apply(version.attributes, rich: rich)
        case .symlink:
            let link = try macLink(version.link, attributes: version.attributes, at: path)
            try target.createLink(link, at: path)
            try target.applyLinkTime(version.attributes, at: path)
        case .unsupported:
            throw BackupError.message("不支持的历史文件类型")
        }
    }

    func prune(now: Date, onWrite: (Int) -> Void) throws {
        let cutoff = now.addingTimeInterval(-Double(BackupJob.retentionDays) * 86400)
        let expired = try catalog.versions().filter { $0.item.date < cutoff }
        if !expired.isEmpty {
            var batch = try newBatch()
            batch.pruned = expired.map(\.item.id)
            try commit(batch, patches: [:], beforeApply: {})
        }

        let packs = try catalog.packs()
        let used = try catalog.usedPacks()
        let unused = packs.subtracting(used)
        if !unused.isEmpty {
            var batch = try newBatch()
            batch.retiredPacks = Array(unused)
            try commit(batch, patches: [:], beforeApply: {})
        }
        // Compact one fragmented segment per maintenance pass.
        for pack in used.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let stamp = try tree.entry(packed(pack)), stamp.size >= Int64(1024 * 1024) else { continue }
            let live = try catalog.liveChunks(in: pack)
            guard live.reduce(Int64(0), { $0 + Int64($1.length) }) < stamp.size / 2 else { continue }
            var batch = try newBatch()
            let writer = PackWriter(repository: self, id: batch.id)
            for chunk in live {
                let data = try readChunk(chunk)
                _ = try writer.save(data, hash: chunk.hash, reuse: false)
                onWrite(data.count)
            }
            batch.chunks = try writer.finish()
            batch.retiredPacks = [pack]
            try commit(batch, patches: [:], beforeApply: {})
            break
        }
        try interruption?(.pruning)
        try removeOrphans()
    }

    private func removeOrphans() throws {
        let packs = try catalog.packs()
        let clones = try Set(catalog.versions().compactMap(\.clone))
        for (directory, kept) in [(packPath, packs), (clonePath, clones)] {
            for name in try tree.names(in: directory) {
                if let id = UUID(uuidString: name), !kept.contains(id) {
                    try tree.remove(pathJoin(directory, name))
                }
            }
        }
    }
}

final class PackWriter {
    let repository: Repository
    let id: UUID
    private var file: FD?
    private var positions: [Data: ChunkLocation] = [:]
    private var offset: Int64 = 0
    private var buffered = Data()
    private var bufferedOffset: Int64 = 0
    private let onWrite: ((Int) -> Void)?
    private(set) var bytes: Int64 = 0

    init(repository: Repository, id: UUID, onWrite: ((Int) -> Void)? = nil) {
        self.repository = repository
        self.id = id
        self.onWrite = onWrite
    }

    func contains(_ hash: Data) throws -> Bool {
        try positions[hash] != nil || repository.catalog.chunk(hash) != nil
    }

    @discardableResult
    func save(_ data: Data, hash: Data, reuse: Bool = true) throws -> ChunkLocation {
        if let previous = positions[hash] { return previous }
        if reuse, let previous = try repository.catalog.chunk(hash) { return previous }
        if file == nil { file = try repository.tree.createFile(packed(id)) }
        if buffered.count + data.count > repository.ioProfile.targetWindow { try flushBuffer() }
        if buffered.isEmpty { bufferedOffset = offset }
        buffered.append(data)
        let entry = ChunkLocation(hash: hash, pack: id, offset: offset, length: data.count)
        positions[hash] = entry
        offset += Int64(data.count)
        bytes += Int64(data.count)
        return entry
    }

    private func flushBuffer() throws {
        if !buffered.isEmpty {
            try file!.write(buffered, at: bufferedOffset)
            onWrite?(buffered.count)
            buffered.removeAll(keepingCapacity: true)
        }
    }

    func finish() throws -> [ChunkLocation] {
        try flushBuffer()
        if let file {
            try file.flush(full: true)
            try repository.tree.directory(packPath).flush(directory: true)
        }
        try repository.tree.directory(clonePath).flush(directory: true)
        return Array(positions.values)
    }
}

func copyVerified(_ source: FD, to target: FD, length: Int64, hashes: Data) throws {
    try source.readSequentially(size: length, window: IOProfile.window(.unknown)) { offset, data in
        for start in stride(from: 0, to: data.count, by: blockSize) {
            let block = data[start..<min(start + blockSize, data.count)]
            guard digest(block) == hashes.blockHash(Int(offset / Int64(blockSize)) + start / blockSize) else {
                throw BackupError.message("备份文件校验失败：\(source.label)")
            }
        }
        try target.write(data, at: offset)
    }
}
