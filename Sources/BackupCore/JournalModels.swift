import Foundation

struct Marker: Codable {
    let version: Int
    let job: UUID
    let volume: String
    let format: DiskFormat
    let sourceIdentity: String
    let sourcePath: String
}

struct DiskEdit: Codable, Sendable {
    enum Method: String, Codable, Sendable {
        case record, install, patch, attributes, remove, move, caseMove
    }

    var method: Method
    let path: String
    var from: String?
    var before: FileStamp?
    var originalAttributes: MacAttributes?
    var archive: ArchivedVersion?
    var next: FileRecord?
    var staging: UUID?
    var rollbackBlocks: [Int] = []
    var activity: Activity?
}

struct DiskBatch: Codable {
    let id: UUID
    let generation: Int64
    var edits: [DiskEdit] = []
    var chunks: [ChunkLocation] = []
    var pruned: [UUID] = []
    var retiredPacks: [UUID] = []
}

struct Envelope: Codable {
    let body: Data
    let checksum: Data

    init(_ batch: DiskBatch) throws {
        body = try JSONEncoder().encode(batch)
        checksum = digest(body)
    }

    func batch() throws -> DiskBatch {
        guard digest(body) == checksum else { throw BackupError.message("备份记录校验失败") }
        return try JSONDecoder().decode(DiskBatch.self, from: body)
    }
}

enum InterruptionPoint: Sendable, Equatable {
    case prepared, firstBlock, applied, committed, pruning
}
