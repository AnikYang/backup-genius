import Foundation
import Darwin

public enum DiskFormat: String, Codable, Sendable {
    case apfs, exfat

    public var name: String { self == .apfs ? "APFS" : "exFAT" }
}

public struct VolumeInfo: Sendable, Equatable {
    public let name: String
    public let mount: URL
    public let identifier: String
    public let format: DiskFormat
    public let availableBytes: Int64
    public let totalBytes: Int64
    public let caseSensitive: Bool
    public let isExternal: Bool
    public let isSolidState: Bool
}

public struct BackupJob: Codable, Sendable, Identifiable {
    public let id: UUID
    public let source: URL
    public let target: URL
    public let volumeID: String
    public let volumeName: String
    public let format: DiskFormat
    public let sourceBookmark: Data?
    public let targetBookmark: Data?
    let sourceIdentity: String
    public let targetRelativePath: String
    public var automatic: Bool
    public let restoreOnly: Bool

    public static let retentionDays = 30
}

public enum SyncState: String, Codable, Sendable {
    case unconfigured, disconnected, ready, checking, syncing, recovering, verifying
    case upToDate, paused, needsAttention, takeoverRequired

    public var busy: Bool {
        switch self {
        case .checking, .syncing, .recovering, .verifying: true
        default: false
        }
    }
}

public struct SyncProgress: Codable, Sendable {
    public var state: SyncState = .unconfigured
    public var examined = 0
    public var processed = 0
    public var planned = 0
    public var skipped = 0
    public var trackedFiles = 0
    public var unmanaged = 0
    public var sourceReadBytes: Int64 = 0
    public var targetReadBytes: Int64 = 0
    public var latestWrittenBytes: Int64 = 0
    public var historyWrittenBytes: Int64 = 0
    public var checkingSeconds: Double = 0
    public var elapsedSeconds: Double = 0
    public var lastSuccess: Date?
    public var currentPath: String?
    public var message: String?
    public var issueCount = 0

    public init(state: SyncState = .unconfigured, trackedFiles: Int = 0, unmanaged: Int = 0,
                lastSuccess: Date? = nil) {
        self.state = state
        self.trackedFiles = trackedFiles
        self.unmanaged = unmanaged
        self.lastSuccess = lastSuccess
    }

    public var fraction: Double? {
        guard state == .syncing, planned > 0 else { return nil }
        return min(1, Double(processed) / Double(planned))
    }
}

public struct Activity: Codable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case added, updated, moved, deleted, issue, recovered, verified
    }

    public var id = UUID()
    public let date: Date
    public let kind: Kind
    public let path: String
    public let detail: String?
    public let bytes: Int64
}

public struct HistoryItem: Codable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let path: String
    public let size: Int64
    public let reason: Activity.Kind
}

public enum BackupError: LocalizedError, Sendable {
    case message(String)
    case io(String, String, Int32)
    case unstable(String)
    case disconnected
    case paused
    case injected

    public var errorDescription: String? {
        switch self {
        case let .message(value): value
        case let .io(action, path, code): "\(action) \(path)：\(String(cString: strerror(code)))"
        case let .unstable(path): "等待文件稳定：\(path)"
        case .disconnected: "等待指定硬盘连接"
        case .paused: "备份已暂停"
        case .injected: "测试中断"
        }
    }

    static func posix(_ action: String, _ path: String) -> Self {
        .io(action, path, errno)
    }
}

enum EntryKind: String, Codable, Sendable {
    case regular, directory, symlink, unsupported
}

struct FileTime: Codable, Equatable, Sendable {
    let seconds: Int
    let nanoseconds: Int

    init(_ time: timespec) {
        seconds = time.tv_sec
        nanoseconds = time.tv_nsec
    }

    init(seconds: Int, nanoseconds: Int) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    var valid: Bool { (0..<1_000_000_000).contains(nanoseconds) }

    var posix: timespec { timespec(tv_sec: seconds, tv_nsec: nanoseconds) }
}

struct FileStamp: Codable, Equatable, Sendable {
    let kind: EntryKind
    let inode: UInt64
    let size: Int64
    let modified: FileTime
    let changed: FileTime
    let birth: FileTime
    let mode: UInt16
    let links: UInt16
    let flags: UInt32

    init(_ raw: stat) {
        switch raw.st_mode & S_IFMT {
        case S_IFREG: kind = .regular
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        default: kind = .unsupported
        }
        inode = raw.st_ino
        size = raw.st_size
        modified = FileTime(raw.st_mtimespec)
        changed = FileTime(raw.st_ctimespec)
        birth = FileTime(raw.st_birthtimespec)
        mode = raw.st_mode & 0o7777
        links = raw.st_nlink
        flags = raw.st_flags
    }

    var portable: Self {
        var raw = stat()
        switch kind {
        case .regular: raw.st_mode = S_IFREG
        case .directory: raw.st_mode = S_IFDIR
        case .symlink: raw.st_mode = S_IFLNK
        case .unsupported: break
        }
        raw.st_size = kind == .regular ? size : 0
        raw.st_mtimespec = modified.posix
        return Self(raw)
    }

    var identity: String { "\(inode):\(birth.seconds):\(birth.nanoseconds)" }

    func sameContentIdentity(as other: Self) -> Bool {
        kind == other.kind && identity == other.identity && size == other.size &&
            modified == other.modified && mode == other.mode && flags == other.flags
    }

    func matchesTarget(_ other: Self, format: DiskFormat) -> Bool {
        guard kind == other.kind else { return false }
        if kind == .directory { return format == .exfat || identity == other.identity }
        if format == .exfat { return size == other.size && modified == other.modified }
        return self == other
    }
}

struct MacAttributes: Codable, Equatable, Sendable {
    var mode: UInt16
    var modified: FileTime
    var birth: FileTime
    var extended: [String: Data] = [:]
    var acl: String?
    var windows: UInt32? = nil
    var windowsLink: Bool? = nil
    var windowsLinkDirectory: Bool? = nil
}

struct FileRecord: Codable, Sendable {
    var path: String
    var source: FileStamp
    var target: FileStamp?
    var attributes: MacAttributes
    var hashes = Data()
    var link: Data?
    var portableID: UUID? = nil
}

struct ChunkLocation: Codable, Hashable, Sendable {
    let hash: Data
    let pack: UUID
    let offset: Int64
    let length: Int
}

struct ArchivedVersion: Codable, Sendable {
    let item: HistoryItem
    let kind: EntryKind
    let attributes: MacAttributes
    var clone: UUID?
    var hashes = Data()
    var link: Data?
}

func macLink(_ target: Data?, attributes: MacAttributes, at path: String) throws -> Data {
    guard let target else { throw BackupError.message("缺少符号链接数据：\(path)") }
    if attributes.windowsLink == true {
        guard let value = String(data: target, encoding: .utf8), !value.hasPrefix("/"), !value.contains(":"),
              !value.contains("\\") else { throw BackupError.message("此符号链接需要在 Windows 恢复：\(path)") }
    }
    return target
}

struct Changes: Sendable {
    var paths: [String: UInt32] = [:]
    var cursor: UInt64 = 0
    var fullScan = false
    var resetCursor = false

    var empty: Bool { paths.isEmpty && cursor == 0 && !fullScan && !resetCursor }
}
