import Foundation

public enum TakeoverChoice: String, Codable, CaseIterable, Sendable {
    case local, disk, both
}

public struct TakeoverChange: Identifiable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case receive, send, conflict, blocked }
    public let path: String
    public let kind: Kind
    public let canKeepBoth: Bool
    public var id: String { path }
}

public struct TakeoverPreview: Codable, Sendable {
    public let id: UUID
    public let generation: Int64
    public let changes: [TakeoverChange]
    public var resuming = false
}

struct TakeoverDraft {
    var preview: TakeoverPreview
    var local: [String: FileRecord]
    var disk: [String: FileRecord]
}

struct AlignmentStep: Codable {
    let path: String
    let before: FileRecord?
    let desired: FileRecord?
    var copyLocal: String? = nil
    let archive: UUID

    private enum CodingKeys: String, CodingKey { case path, before, desired, copyLocal, archive }

    init(path: String, before: FileRecord?, desired: FileRecord?, copyLocal: String? = nil, archive: UUID = UUID()) {
        self.path = path
        self.before = before
        self.desired = desired
        self.copyLocal = copyLocal
        self.archive = archive
    }
}

struct AlignmentCheckpoint: Codable {
    let source: String
    let writer: UUID?
    var preview: TakeoverPreview
    let disk: [String: FileRecord]
    let steps: [AlignmentStep]
}

func equalContents(_ left: FileRecord?, _ right: FileRecord?) -> Bool {
    guard let left, let right else { return left == nil && right == nil }
    return left.source.kind == right.source.kind && left.hashes == right.hashes && left.link == right.link &&
        (left.source.kind != .regular || left.source.size == right.source.size)
}

func equalContents(_ left: [String: FileRecord], _ right: [String: FileRecord]) -> Bool {
    left.count == right.count && left.allSatisfy { equalContents($0.value, right[$0.key]) }
}

func readAlignmentEntry(_ tree: Tree, _ path: String) throws -> FileRecord? {
    guard let stamp = try tree.entry(path) else { return nil }
    guard stamp.kind != .unsupported else { throw BackupError.message("无法对齐此文件类型：\(path)") }
    let attrs = try tree.attributes(path, stamp: stamp, rich: true)
    let hashes = stamp.kind == .regular ? try tree.file(path).fileHashes(size: stamp.size) : Data()
    let link = stamp.kind == .symlink ? try tree.readLink(path) : nil
    guard try tree.entry(path) == stamp else { throw BackupError.unstable(path) }
    return FileRecord(path: path, source: stamp, attributes: attrs, hashes: hashes, link: link)
}

func localAlignment(_ tree: Tree) throws -> [String: FileRecord] {
    var result: [String: FileRecord] = [:]
    try tree.scan { path, _ in
        try userPath(path)
        result[path] = try readAlignmentEntry(tree, path)
    }
    try tree.checkRoot()
    return result
}

extension Repository {
    func verifiedAlignment() throws -> [String: FileRecord] {
        var result: [String: FileRecord] = [:]
        try catalog.visitFiles { record in
            let actual = try tree.entry(record.path)
            switch record.source.kind {
            case .symlink:
                guard actual == nil, record.link != nil else { throw BackupError.unstable(record.path) }
            case .regular:
                guard let actual, actual.kind == .regular, actual.size == record.source.size,
                      try tree.file(record.path).fileHashes(size: actual.size) == record.hashes,
                      try tree.entry(record.path) == actual else { throw BackupError.unstable(record.path) }
            case .directory:
                guard actual?.kind == .directory else { throw BackupError.unstable(record.path) }
            case .unsupported: throw BackupError.message("无法接管此文件类型：\(record.path)")
            }
            result[record.path] = record
        }
        try tree.checkRoot()
        return result
    }

    func archiveLocal(_ record: FileRecord, from source: Tree, id: UUID) throws {
        if try catalog.version(id) != nil { return }
        var batch = try newBatch()
        let writer = PackWriter(repository: self, id: batch.id)
        let size = record.source.kind == .regular ? record.source.size : 0
        if record.source.kind == .regular {
            let file = try source.file(record.path)
            var offset: Int64 = 0
            for i in 0..<(record.hashes.count / digestSize) {
                let bytes = try file.readExact(at: offset, length: Int(min(Int64(blockSize), size - offset)))
                let hash = digest(bytes)
                guard hash == record.hashes.blockHash(i) else { throw BackupError.unstable(record.path) }
                try writer.save(bytes, hash: hash)
                offset += Int64(bytes.count)
            }
        }
        let version = ArchivedVersion(item: HistoryItem(id: id, date: .now, path: record.path, size: size, reason: .updated),
                                      kind: record.source.kind, attributes: record.attributes, hashes: record.hashes, link: record.link)
        let activity = Activity(date: .now, kind: .updated, path: record.path, detail: "接管前归档本机文件", bytes: 0)
        batch.edits = [DiskEdit(method: .archive, path: record.path, archive: version, activity: activity)]
        batch.chunks = try writer.finish()
        try commit(batch, patches: [:]) {
            guard try source.entry(record.path) == record.source else { throw BackupError.unstable(record.path) }
        }
    }

    func applyAlignment(_ step: AlignmentStep, source: Tree) throws {
        try userPath(step.path)
        let current = try readAlignmentEntry(source, step.path)
        if equalContents(current, step.desired) { return }
        guard equalContents(current, step.before) else { throw BackupError.unstable(step.path) }
        if let current { try archiveLocal(current, from: source, id: step.archive) }
        guard let incoming = step.desired else {
            if let current {
                guard try source.entry(step.path) == current.source || current.source.kind == .directory else {
                    throw BackupError.unstable(step.path)
                }
                try source.remove(step.path, directory: current.source.kind == .directory, keepNonEmpty: true)
                try source.directory(pathParent(step.path)).flush(directory: true)
            }
            return
        }
        try source.makeParents(of: step.path)
        if incoming.source.kind == .directory {
            try source.mkdir(step.path, existing: true)
            try source.directory(pathParent(step.path)).flush(directory: true)
            return
        }
        let temporary = pathJoin(pathParent(step.path), ".backup-genius-align-\(step.archive.uuidString)")
        // The temporary is ours only if created during this attempt. A crash can
        // leave it behind, so a retry verifies its contents before reusing it.
        if let existing = try readAlignmentEntry(source, temporary), !equalContents(existing, incoming) {
            guard existing.source.kind != .directory else { throw BackupError.unstable(temporary) }
            try source.remove(temporary)
        }
        if try source.entry(temporary) == nil {
            do {
                switch incoming.source.kind {
                case .regular:
                    let input = try (step.copyLocal == nil ? tree : source).file(step.copyLocal ?? incoming.path)
                    let output = try source.createFile(temporary)
                    try copyVerified(input, to: output, length: incoming.source.size, hashes: incoming.hashes)
                    try output.apply(incoming.attributes, rich: true)
                    try output.flush(full: true)
                case .symlink:
                    let link = try macLink(incoming.link, attributes: incoming.attributes, at: step.path)
                    try source.createLink(link, at: temporary)
                    try source.applyLinkTime(incoming.attributes, at: temporary)
                default: throw BackupError.message("无法恢复此文件类型")
                }
            } catch {
                try? source.remove(temporary)
                throw error
            }
        }
        guard try source.entry(step.path) == current?.source else { throw BackupError.unstable(step.path) }
        try source.rename(temporary, to: step.path, replacing: current != nil)
        try source.directory(pathParent(step.path)).flush(directory: true)
    }
}

func compareAlignment(local: [String: FileRecord], disk: [String: FileRecord], base: [String: FileRecord]) -> [TakeoverChange] {
    var result: [TakeoverChange] = []
    var names: [String: String] = [:]
    var blocked = Set<String>()
    let paths = Set(local.keys).union(disk.keys).sorted()
    for path in paths {
        let key = pathKey(path, caseSensitive: false)
        if let other = names[key], other != path { blocked.formUnion([path, other]) }
        names[key] = path
        if windowsNameProblem(path) { blocked.insert(path) }
        if let remote = disk[path], remote.source.kind == .symlink,
           (try? macLink(remote.link, attributes: remote.attributes, at: path)) == nil { blocked.insert(path) }
        if let l = local[path], let r = disk[path], l.source.kind != r.source.kind,
           l.source.kind == .directory || r.source.kind == .directory { blocked.insert(path) }
    }
    for path in paths {
        let l = local[path], r = disk[path], b = base[path]
        if blocked.contains(path) {
            result.append(TakeoverChange(path: path, kind: .blocked, canKeepBoth: false))
        } else if !equalContents(l, r) {
            let kind: TakeoverChange.Kind = equalContents(l, b) ? .receive : (equalContents(r, b) ? .send : .conflict)
            let canKeepBoth = l != nil && r != nil && l?.source.kind != .directory && r?.source.kind != .directory
            result.append(TakeoverChange(path: path, kind: kind, canKeepBoth: canKeepBoth))
        }
    }
    return result
}
