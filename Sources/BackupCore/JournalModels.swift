import Foundation

struct Marker: Codable {
    let version: Int
    let job: UUID
    var volume: String? = nil
    let format: DiskFormat
    var sourceIdentity: String? = nil
    var sourcePath: String? = nil
    var initialWriter: UUID? = nil
    var legacyGeneration: Int64? = nil

    var portable: Bool { version == 2 }
}

struct DiskEdit: Codable, Sendable {
    enum Method: String, Codable, Sendable {
        case record, install, patch, attributes, remove, move, caseMove, archive
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
    var version: Int? = nil
    var writer: UUID? = nil
    var takeover: Bool? = nil
    var run: BackupRunTag? = nil
}

struct BackupRunTag: Codable, Sendable {
    let id: UUID
    let started: Date
}

struct Envelope: Codable {
    let body: Data
    let checksum: Data

    init(_ batch: DiskBatch) throws {
        let encoder = JSONEncoder()
        if batch.version == 2 {
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var value = date.timeIntervalSince1970
                var seconds = floor(value)
                value = ((value - seconds) * 1_000_000_000).rounded()
                if value == 1_000_000_000 { seconds += 1; value = 0 }
                try FileTime(seconds: Int(seconds), nanoseconds: Int(value)).encode(to: encoder)
            }
        }
        body = try encoder.encode(batch)
        checksum = digest(body)
    }

    func batch() throws -> DiskBatch {
        guard digest(body) == checksum else { throw BackupError.message("备份记录校验失败") }
        struct Header: Decodable { let version: Int? }
        let decoder = JSONDecoder()
        let version = try decoder.decode(Header.self, from: body).version
        if version == 2 {
            decoder.dateDecodingStrategy = .custom { decoder in
                let time = try FileTime(from: decoder)
                guard time.valid else { throw BackupError.message("备份记录的时间无效") }
                return Date(timeIntervalSince1970: Double(time.seconds) + Double(time.nanoseconds) / 1e9)
            }
        } else if version != nil {
            throw BackupError.message("不支持的备份记录版本")
        }
        return try decoder.decode(DiskBatch.self, from: body)
    }
}

enum InterruptionPoint: Sendable, Equatable {
    case prepared, firstBlock, applied, committed, pruning
}
