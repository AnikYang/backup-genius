import Foundation

public struct RestorePoint: Identifiable, Sendable, Codable {
    public let id: UUID
    public let date: Date
    public let files: Int
}

// Separate immutable storage: older v1/v2 clients cannot prune these packs.
// A small final record publishes a point only after every segment and pack is durable.
private let pointsRoot = "\(controlName)/points"
private struct PointEntry: Codable {
    let path: String
    var record: FileRecord?
    var clone: UUID?
}
private struct PointSegment: Codable {
    let entries: [PointEntry]
    let chunks: [ChunkLocation]
}
private struct PointRecord: Codable {
    let version: Int
    let id: UUID
    let previous: UUID?
    let sequence: Int
    let created: FileTime
    let files: Int
    let segments: [UUID]
    var generation: Int64? = nil
    var date: Date { Date(timeIntervalSince1970: Double(created.seconds) + Double(created.nanoseconds) / 1e9) }
    var summary: RestorePoint { RestorePoint(id: id, date: date, files: files) }
}

final class RestorePointStore {
    private let repository: Repository
    private var contentsLoaded = false
    private let tree: Tree
    private let rich: Bool
    private var records: [PointRecord] = []
    private var entries: [String: PointEntry] = [:]
    private var chunks: [Data: ChunkLocation] = [:]
    private var committedPacks = Set<UUID>()
    private var committedClones = Set<UUID>()
    private var committedSegments = Set<UUID>()
    private let fault: ((InterruptionPoint) throws -> Void)?

    init(_ repository: Repository, fault: ((InterruptionPoint) throws -> Void)? = nil) throws {
        self.repository = repository
        tree = repository.tree
        rich = repository.volume.format == .apfs
        self.fault = fault
        guard try tree.entry(pointsRoot) != nil else { return }
        if try tree.entry("\(pointsRoot)/records") == nil, try tree.names(in: pointsRoot).isEmpty { return }
        var previous: UUID?
        let names = try tree.names(in: "\(pointsRoot)/records").filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted()
        for (index, name) in names.enumerated() {
            let record: PointRecord = try read("records/\(name)")
            guard record.version == 1, record.sequence == index + 1, record.previous == previous,
                  record.created.valid, record.files >= 0,
                  name == Self.name(index + 1) else { throw BackupError.message("备份时间点记录顺序异常") }
            records.append(record)
            previous = record.id
        }
    }

    private func loadContents() throws {
        guard !contentsLoaded else { return }
        for record in records { try apply(record, to: &entries) }
        guard try tree.entry(pointsRoot) != nil else { contentsLoaded = true; return }
        let present = Set(try tree.names(in: "\(pointsRoot)/packs").compactMap(UUID.init(uuidString:)))
        chunks = chunks.filter { present.contains($0.value.pack) }
        contentsLoaded = true
    }

    private static func name(_ sequence: Int) -> String { String(format: "%020d.json", sequence) }
    private func read<T: Decodable>(_ path: String) throws -> T {
        try tree.readDocument(Envelope.self, from: "\(pointsRoot)/\(path)").document(T.self)
    }
    private func write<T: Encodable>(_ value: T, _ path: String) throws {
        try tree.writeDocument(Envelope(document: value), at: "\(pointsRoot)/\(path)")
    }
    private func apply(_ point: PointRecord, to state: inout [String: PointEntry], collect: Bool = true, visit: ((PointEntry) -> Void)? = nil) throws {
        for id in point.segments {
            if collect { committedSegments.insert(id) }
            let segment: PointSegment = try read("segments/\(id.uuidString)")
            for chunk in segment.chunks {
                guard chunk.hash.count == digestSize, chunk.offset >= 0, chunk.length > 0,
                      chunk.length <= blockSize, chunk.offset <= Int64.max - Int64(chunk.length) else {
                    throw BackupError.message("备份时间点的数据位置无效")
                }
                if collect { chunks[chunk.hash] = chunk; committedPacks.insert(chunk.pack) }
            }
            for entry in segment.entries {
                try userPath(entry.path)
                if let record = entry.record {
                    guard record.path == entry.path, record.source.size >= 0,
                          record.hashes.count % digestSize == 0 else { throw BackupError.message("备份时间点文件记录无效") }
                    if record.source.kind == .regular {
                        let count = record.source.size / Int64(blockSize) + (record.source.size % Int64(blockSize) == 0 ? 0 : 1)
                        guard count == record.hashes.count / digestSize else { throw BackupError.message("备份时间点文件校验值不完整") }
                    }
                    guard rich || entry.clone == nil else { throw BackupError.message("此时间点需要在原 APFS 硬盘上恢复") }
                    if collect, let clone = entry.clone { committedClones.insert(clone) }
                    state[entry.path] = entry
                    visit?(entry)
                } else { state.removeValue(forKey: entry.path) }
            }
        }
    }

    func list(now: Date = .now) -> [RestorePoint] {
        let cutoff = now.addingTimeInterval(-Double(BackupJob.retentionDays) * 86400)
        return records.filter { $0.date >= cutoff || $0.id == records.last?.id }.reversed().map(\.summary)
    }

    @discardableResult
    func capture(catalog: Catalog, now: Date = .now, shouldStop: () -> Bool = { false }, onRead: (Int) -> Void, onWrite: (Int) -> Void) throws -> RestorePoint {
        try tree.mkdir(pointsRoot, existing: true)
        for dir in ["records", "segments", "packs", "clones"] { try tree.mkdir("\(pointsRoot)/\(dir)", existing: true) }
        if shouldStop() { throw BackupError.paused }
        let generation = try catalog.generation
        if records.last?.generation == generation {
            return try publishPoint(now: now, files: records.last!.files, segments: [], generation: generation)
        }
        try loadContents()
        try discardUnpublishedData()
        var changes: [PointEntry] = []
        var locations: [ChunkLocation] = []
        var segments: [UUID] = []
        var seen = Set<String>()
        var pack: FD?
        var packID = UUID()
        var offset: Int64 = 0
        var count = 0
        var clonedFiles = false
        func flushSegment() throws {
            guard !changes.isEmpty else { return }
            if clonedFiles {
                try tree.directory("\(pointsRoot)/clones").flush(directory: true)
                clonedFiles = false
            }
            try pack?.flush(full: true)
            if pack != nil { try tree.directory("\(pointsRoot)/packs").flush(directory: true) }
            let id = UUID()
            try write(PointSegment(entries: changes, chunks: locations), "segments/\(id.uuidString)")
            segments.append(id)
            changes.removeAll(keepingCapacity: true)
            locations.removeAll(keepingCapacity: true)
            pack = nil
            packID = UUID()
            offset = 0
        }
        try catalog.visitFiles { record in
            if shouldStop() { throw BackupError.paused }
            try userPath(record.path)
            seen.insert(record.path)
            if record.source.kind != .directory { count += 1 }
            let old = entries[record.path]
            let sameContent = old?.record.map {
                $0.source.kind == record.source.kind && $0.source.size == record.source.size &&
                $0.hashes == record.hashes && $0.link == record.link
            } ?? false
            if sameContent, old?.record?.attributes == record.attributes { return }
            var entry = PointEntry(path: record.path, record: record, clone: sameContent ? old?.clone : nil)
            if record.source.kind == .regular && !sameContent {
                let input = try tree.file(record.path)
                let stamp = try input.stamp()
                guard stamp == record.target else { throw BackupError.unstable(record.path) }
                if rich {
                    let id = UUID()
                    try tree.clone(input, to: "\(pointsRoot)/clones/\(id.uuidString)")
                    // Flush the inode, then use the segment's full-device barrier
                    // after flushing the shared clone directory once per batch.
                    try tree.file("\(pointsRoot)/clones/\(id.uuidString)").flush()
                    clonedFiles = true
                    entry.clone = id
                } else {
                    for index in 0..<(record.hashes.count / digestSize) {
                        if shouldStop() { throw BackupError.paused }
                        let hash = record.hashes.blockHash(index)!
                        if chunks[hash] != nil { continue }
                        let start = Int64(index) * Int64(blockSize)
                        let data = try input.readExact(at: start, length: Int(min(Int64(blockSize), stamp.size - start)))
                        onRead(data.count)
                        guard digest(data) == hash else { throw BackupError.unstable(record.path) }
                        if pack == nil { pack = try tree.createFile("\(pointsRoot)/packs/\(packID.uuidString)") }
                        try pack!.write(data, at: offset)
                        onWrite(data.count)
                        let location = ChunkLocation(hash: hash, pack: packID, offset: offset, length: data.count)
                        locations.append(location)
                        chunks[hash] = location
                        offset += Int64(data.count)
                    }
                }
                guard try input.stamp() == stamp else { throw BackupError.unstable(record.path) }
            }
            changes.append(entry)
            if changes.count >= IOProfile.batchSize { try flushSegment() }
        }
        for path in entries.keys.sorted() where !seen.contains(path) {
            changes.append(PointEntry(path: path))
            if changes.count >= IOProfile.batchSize { try flushSegment() }
        }
        try flushSegment()
        let summary = try publishPoint(now: now, files: count, segments: segments, generation: generation)
        if let point = records.last { try apply(point, to: &entries) }
        return summary
    }

    private func publishPoint(now: Date, files: Int, segments: [UUID], generation: Int64) throws -> RestorePoint {
        try fault?(.pointPrepared)
        let seconds = floor(now.timeIntervalSince1970)
        let point = PointRecord(version: 1, id: UUID(), previous: records.last?.id, sequence: records.count + 1,
                                created: FileTime(seconds: Int(seconds), nanoseconds: Int((now.timeIntervalSince1970 - seconds) * 1e9)),
                                files: files, segments: segments, generation: generation)
        try write(point, "records/\(Self.name(point.sequence))")
        try fault?(.pointCommitted)
        records.append(point)
        return point.summary
    }

    func restore(_ id: UUID, to output: Tree, at root: String, now: Date = .now) throws {
        guard list(now: now).contains(where: { $0.id == id }) else { throw BackupError.message("此备份时间点已过期或不存在") }
        try loadContents()
        var snapshot: [String: PointEntry] = [:]
        for point in records {
            try apply(point, to: &snapshot, collect: false)
            if point.id == id { break }
        }
        var directories: [(String, MacAttributes)] = []
        for entry in snapshot.values.sorted(by: { $0.path < $1.path }) {
            guard let record = entry.record else { continue }
            let path = pathJoin(root, entry.path)
            try output.makeParents(of: path)
            switch record.source.kind {
            case .regular:
                let out = try output.createFile(path)
                if let clone = entry.clone {
                    try copyVerified(tree.file("\(pointsRoot)/clones/\(clone.uuidString)"), to: out,
                                     length: record.source.size, hashes: record.hashes)
                } else {
                    var offset: Int64 = 0
                    for index in 0..<(record.hashes.count / digestSize) {
                        let hash = record.hashes.blockHash(index)!
                        guard let chunk = chunks[hash] else { throw BackupError.message("时间点缺少文件数据：\(entry.path)") }
                        let data = try tree.file("\(pointsRoot)/packs/\(chunk.pack.uuidString)").readExact(at: chunk.offset, length: chunk.length)
                        guard digest(data) == hash else { throw BackupError.message("时间点内容校验失败：\(entry.path)") }
                        try out.write(data, at: offset)
                        offset += Int64(data.count)
                    }
                    guard offset == record.source.size else { throw BackupError.message("时间点文件大小不符：\(entry.path)") }
                }
                try out.apply(record.attributes, rich: true)
                try out.flush()
            case .directory:
                try output.mkdir(path, existing: true)
                directories.append((path, record.attributes))
            case .symlink:
                try output.createLink(macLink(record.link, attributes: record.attributes, at: entry.path), at: path)
                try output.applyLinkTime(record.attributes, at: path)
            case .unsupported: throw BackupError.message("此项目需要在原系统恢复：\(entry.path)")
            }
        }
        for (path, attrs) in directories.sorted(by: { $0.0.count > $1.0.count }) { try output.directory(path).apply(attrs, rich: true) }
    }

    private func discardUnpublishedData() throws {
        for (directory, referenced) in [("packs", committedPacks), ("clones", committedClones), ("segments", committedSegments)] {
            for name in try tree.names(in: "\(pointsRoot)/\(directory)") {
                if let id = UUID(uuidString: name), !referenced.contains(id) {
                    try tree.remove("\(pointsRoot)/\(directory)/\(name)")
                }
            }
        }
    }

    func prune(now: Date = .now) throws {
        try loadContents()
        let retained = Set(list(now: now).map(\.id))
        var state: [String: PointEntry] = [:]
        var livePacks = Set<UUID>()
        var liveClones = Set<UUID>()
        func retain(_ entry: PointEntry) {
            if let clone = entry.clone { liveClones.insert(clone) }
            else if let record = entry.record, record.source.kind == .regular {
                for index in 0..<(record.hashes.count / digestSize) {
                    if let chunk = chunks[record.hashes.blockHash(index)!] { livePacks.insert(chunk.pack) }
                }
            }
        }
        var retaining = false
        for point in records {
            try apply(point, to: &state, collect: false, visit: retaining ? retain : nil)
            if !retaining, retained.contains(point.id) {
                retaining = true
                for entry in state.values { retain(entry) }
            }
        }
        // Metadata deltas remain as the replay chain. Only unreferenced data is removed.
        for (directory, live) in [("packs", livePacks), ("clones", liveClones)] {
            for name in try tree.names(in: "\(pointsRoot)/\(directory)") {
                if let id = UUID(uuidString: name), !live.contains(id) {
                    try fault?(.pointPruning)
                    try tree.remove("\(pointsRoot)/\(directory)/\(name)")
                }
            }
        }
        // Removed packs must not be reused by subsequent captures.
        chunks = chunks.filter { livePacks.contains($0.value.pack) }
    }
}
