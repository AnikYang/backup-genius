import Foundation
import Darwin

public struct FolderMapping: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let job: UUID
    public internal(set) var folder: String
    public internal(set) var enabled: Bool

    public var name: String { pathName(folder) }
    public var group: String { pathParent(folder) }
}

public struct BackupSet: Codable, Sendable, Identifiable, Equatable {
    public static let folderName = "BackupGenius"
    public let layout: Int
    public let id: UUID
    public let format: DiskFormat
    public internal(set) var revision: Int64
    public internal(set) var mappings: [FolderMapping]

    init(id: UUID = UUID(), format: DiskFormat) {
        layout = 2
        self.id = id
        self.format = format
        revision = 0
        mappings = []
    }

    func validate(on volume: VolumeInfo) throws {
        guard layout == 2, format == volume.format, revision > 0, !mappings.isEmpty,
              Set(mappings.map(\.id)).count == mappings.count,
              Set(mappings.map(\.job)).count == mappings.count else {
            throw BackupError.message("备份集合的识别记录无效")
        }
        var destinations = Set<String>()
        for mapping in mappings {
            let parts = try pathComponents(mapping.folder)
            guard (1...2).contains(parts.count), !parts.contains(where: { isBackupControl(String($0)) }),
                  destinations.insert(pathKey(mapping.folder, caseSensitive: volume.caseSensitive)).inserted else {
                throw BackupError.message("备份集合中的文件夹位置冲突：\(mapping.folder)")
            }
        }
        guard !destinations.contains(where: { destinations.contains(pathParent($0)) }) else {
            throw BackupError.message("备份集合中的文件夹位置重叠")
        }
    }

    static func target(_ folder: String) -> String { pathJoin(folderName, folder) }
}

public struct BackupSetupRow: Sendable, Identifiable {
    public let id: UUID
    public let source: URL?
    public let name: String
    public internal(set) var group: String
    public let previousFolder: String?

    public var folder: String { pathJoin(group, name) }
}

public struct BackupSetupPreview: Sendable, Identifiable {
    public let id: UUID
    public let volume: VolumeInfo
    public let rows: [BackupSetupRow]
}

struct SetMove: Codable {
    let from: String
    let to: String
    let job: UUID
}

struct SetTransition: Codable {
    let base: Int64
    let next: BackupSet
    let additions: [Marker]
    let moves: [SetMove]
}

// The set lease stays open while the volume is in use. Member repositories
// retain their own leases and transaction journals.
final class BackupSetStore: @unchecked Sendable {
    static let control = "\(storageName)/set"
    static let pending = "\(control)/pending.json"
    static let marker = "\(BackupSet.folderName)/\(identityName)"
    let disk: Tree
    var volume: VolumeInfo
    private let access: Scope
    private let lock: FD
    private let interrupt: (@Sendable (SetInterruption) throws -> Void)?

    init(_ access: Scope, volume: VolumeInfo, interrupt: (@Sendable (SetInterruption) throws -> Void)? = nil) throws {
        self.access = access
        self.volume = volume
        self.interrupt = interrupt
        disk = try Tree(volume.mount.resolvingSymlinksInPath())
        try disk.mkdir(storageName, existing: true)
        try disk.mkdir(Self.control, existing: true)
        let path = pathJoin(Self.control, "lock")
        do { lock = try disk.createFile(path) }
        catch BackupError.io(_, _, let code) where code == EEXIST { lock = try disk.file(path, writable: true) }
        guard flock(lock.value, LOCK_EX | LOCK_NB) == 0 else {
            throw BackupError.message("此备份硬盘正在另一个进程中使用")
        }
        try disk.directory(storageName).flush(directory: true)
        try disk.root.flush(directory: true)
    }

    static func read(_ disk: Tree, volume: VolumeInfo) throws -> BackupSet? {
        guard try disk.entry(marker) != nil else { return nil }
        let set = try disk.readDocument(BackupSet.self, from: marker)
        try set.validate(on: volume)
        return set
    }

    func read() throws -> BackupSet? { try Self.read(disk, volume: volume) }

    func recover() throws -> BackupSet? {
        try disk.checkRoot()
        guard try disk.entry(Self.pending) != nil else { return try read() }
        let envelope = try disk.readDocument(Envelope.self, from: Self.pending)
        let transition = try envelope.document(SetTransition.self)
        try finish(transition)
        return transition.next
    }

    func apply(_ transition: SetTransition) throws {
        try disk.checkRoot()
        guard try disk.entry(Self.pending) == nil else { throw BackupError.message("请先恢复未完成的目录调整") }
        let current = try read()
        try validate(transition, current: current)
        try checkRootSlot(existing: current != nil)
        for mapping in transition.next.mappings {
            try checkTargetSlot(mapping.folder)
        }
        for move in transition.moves {
            guard try disk.entry(BackupSet.target(move.from))?.kind == .directory else {
                throw BackupError.message("找不到要移动的备份文件夹：\(move.from)")
            }
            let caseOnly = pathKey(move.from, caseSensitive: volume.caseSensitive) ==
                pathKey(move.to, caseSensitive: volume.caseSensitive)
            let destination = try disk.entry(BackupSet.target(move.to))
            guard caseOnly || destination == nil else {
                throw BackupError.message("备份文件夹位置已被占用：\(move.to)")
            }
        }
        try disk.writeDocument(try Envelope(document: transition), at: Self.pending)
        try interrupt?(.prepared)
        try finish(transition)
    }

    private func validate(_ transition: SetTransition, current: BackupSet?) throws {
        let next = transition.next
        try next.validate(on: volume)
        guard transition.base >= 0, transition.base < Int64.max, next.revision == transition.base + 1,
              current == next || ((current?.revision ?? 0) == transition.base && (current == nil || current?.id == next.id))
        else { throw BackupError.message("备份映射已改变，请重新预览") }
        let old = Dictionary(uniqueKeysWithValues: (current?.mappings ?? []).map { ($0.job, $0) })
        let jobs = Set(next.mappings.map(\.job))
        let added = Set(transition.additions.map(\.job))
        for marker in transition.additions {
            let validAPFS = marker.version == 1 && next.format == .apfs && marker.volume == volume.identifier
            let validPortable = marker.version == 2 && next.format == .exfat &&
                marker.initialWriter != nil && marker.legacyGeneration == 0
            guard validAPFS || validPortable else { throw BackupError.message("备份集合的任务记录无效") }
        }
        guard added.count == transition.additions.count,
              transition.additions.allSatisfy({ $0.format == next.format && jobs.contains($0.job) }),
              Set(transition.moves.map(\.job)).count == transition.moves.count else {
            throw BackupError.message("备份集合的恢复记录无效")
        }
        if current != next {
            guard Set(old.keys).isSubset(of: jobs), added == jobs.subtracting(old.keys),
                  next.mappings.allSatisfy({ old[$0.job] == nil || old[$0.job]?.id == $0.id }) else {
                throw BackupError.message("备份集合的任务标识不符")
            }
        }
        for move in transition.moves {
            let components = try pathComponents(move.from)
            guard (1...2).contains(components.count), !components.contains(where: { isBackupControl(String($0)) }),
                  next.mappings.contains(where: { $0.job == move.job && $0.folder == move.to }),
                  current == next || old[move.job]?.folder == move.from else {
                throw BackupError.message("备份集合的移动记录无效")
            }
        }
        if current != next {
            let changed = Set(next.mappings.filter { old[$0.job] != nil && old[$0.job]?.folder != $0.folder }.map(\.job))
            guard changed == Set(transition.moves.map(\.job)) else {
                throw BackupError.message("备份集合的移动记录不完整")
            }
        }
    }

    private func finish(_ transition: SetTransition) throws {
        let current = try read()
        try validate(transition, current: current)
        if current != transition.next {
            try checkRootSlot(existing: current != nil)
            try disk.mkdir(BackupSet.folderName, existing: true)
            for move in transition.moves { try relocate(move, revision: transition.next.revision) }
            for marker in transition.additions {
                guard let mapping = transition.next.mappings.first(where: { $0.job == marker.job }) else { continue }
                try checkTargetSlot(mapping.folder)
                let target = BackupSet.target(mapping.folder)
                try disk.makeParents(of: target)
                try disk.mkdir(target, existing: true)
                try Repository.initializeMember(on: disk, folder: target, marker: marker, volume: volume)
                try disk.directory(pathParent(target)).flush(directory: true)
            }
            try disk.writeDocument(transition.next, at: Self.marker, replacing: current != nil,
                                   stagingIn: Self.control, hidden: true)
            try interrupt?(.published)
        }
        for move in transition.moves {
            let witness = pathJoin(BackupSet.target(move.to), identityName)
            if try disk.entry(witness) != nil {
                try checkWitness(witness, move: move, revision: transition.next.revision)
                try disk.remove(witness)
                try disk.directory(pathParent(witness)).flush(directory: true)
            }
        }
        try disk.remove(Self.pending)
        try disk.directory(Self.control).flush(directory: true)
    }

    private struct Witness: Codable, Equatable {
        let job: UUID
        let revision: Int64
    }

    private func relocate(_ move: SetMove, revision: Int64) throws {
        let from = BackupSet.target(move.from), to = BackupSet.target(move.to)
        let stage = pathJoin(Self.control, move.job.uuidString)
        if try disk.entry(stage) == nil, try exactDirectory(from) {
            let witness = pathJoin(from, identityName)
            if try disk.entry(witness) == nil {
                try disk.writeDocument(Witness(job: move.job, revision: revision), at: witness,
                                       stagingIn: Self.control, hidden: true)
            }
            try checkWitness(witness, move: move, revision: revision)
            try disk.rename(from, to: stage)
            try disk.directory(pathParent(from)).flush(directory: true)
            try disk.directory(Self.control).flush(directory: true)
            try interrupt?(.relocated)
        }
        if try disk.entry(stage) != nil {
            try checkWitness(pathJoin(stage, identityName), move: move, revision: revision)
            try disk.makeParents(of: to)
            try disk.rename(stage, to: to)
            try disk.directory(pathParent(to)).flush(directory: true)
            try disk.directory(Self.control).flush(directory: true)
        }
        try checkWitness(pathJoin(to, identityName), move: move, revision: revision)
    }

    private func exactDirectory(_ path: String) throws -> Bool {
        guard try disk.entry(path)?.kind == .directory else { return false }
        return try disk.names(in: pathParent(path)).contains(pathName(path))
    }

    private func checkWitness(_ path: String, move: SetMove, revision: Int64) throws {
        guard try disk.readDocument(Witness.self, from: path) == Witness(job: move.job, revision: revision) else {
            throw BackupError.message("移动中的备份文件夹与恢复记录不符")
        }
    }

    private func checkRootSlot(existing: Bool) throws {
        if let stamp = try disk.entry(BackupSet.folderName), stamp.kind != .directory {
            throw BackupError.message("硬盘上的 BackupGenius 名称已被占用")
        }
        guard try disk.entry(controlName) == nil, try disk.entry(identityName) == nil,
              try disk.entry(BackupSet.target(controlName)) == nil,
              existing || ((try? disk.entry(BackupSet.target(identitySidecarName))) == nil) else {
            throw BackupError.message("备份位置与已有任务重叠")
        }
    }

    func checkTargetSlot(_ folder: String) throws {
        var relative = BackupSet.folderName
        for component in try pathComponents(folder) {
            relative = pathJoin(relative, String(component))
            if let stamp = try disk.entry(relative) {
                guard stamp.kind == .directory, try disk.entry(pathJoin(relative, controlName)) == nil,
                      try disk.entry(pathJoin(relative, identityName)) == nil else {
                    throw BackupError.message("目标文件夹与已有任务或文件冲突：\(relative)")
                }
            }
        }
    }
}

enum SetInterruption: Equatable, Sendable { case prepared, relocated, published }
