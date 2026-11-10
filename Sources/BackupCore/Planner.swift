import Foundation
import CoreServices

let flagModified = UInt32(kFSEventStreamEventFlagItemModified)
let flagRenamed = UInt32(kFSEventStreamEventFlagItemRenamed)
let flagDirectory = UInt32(kFSEventStreamEventFlagItemIsDir)
let flagSubtree = UInt32(kFSEventStreamEventFlagMustScanSubDirs)
let flagCreated = UInt32(kFSEventStreamEventFlagItemCreated)
let flagRemoved = UInt32(kFSEventStreamEventFlagItemRemoved)

struct Work: Sendable {
    enum Kind: Sendable { case sync, remove, move }
    let kind: Kind
    let path: String
    let stamp: FileStamp?
    let old: FileRecord?
    var forceHash = false
    var from: String?
    var caseOnly = false
    var targetNameMatches = false
}

struct WorkPlan {
    var waves: [[Work]] = []
    var problems: [String: String] = [:]
    var examined = 0
    var unmanaged: Int?
    var existingWork = 0
}

// SwiftPM's .build directory is reproducible. A same-named ordinary hidden
// file or a directory outside a Swift package remains part of the backup.
final class SourceExclusions {
    private let source: Tree
    private var caches: [String: Bool] = [:]

    init(source: Tree) { self.source = source }

    func contains(_ path: String) -> Bool {
        guard path.contains(".build") else { return false }
        var prefix = ""
        for component in path.split(separator: "/") {
            let parent = prefix
            prefix = pathJoin(prefix, String(component))
            guard component == ".build" else { continue }
            if let excluded = caches[prefix] {
                if excluded { return true }
                continue
            }
            let excluded: Bool
            do {
                let entry = try source.entry(prefix)
                let manifest = try source.entry(pathJoin(parent, "Package.swift"))
                excluded = (entry == nil || entry?.kind == .directory) && manifest?.kind == .regular
            } catch {
                excluded = false
            }
            caches[prefix] = excluded
            if excluded { return true }
        }
        return false
    }
}

struct Planner {
    let source: Tree
    let target: Tree
    let catalog: Catalog
    let volume: VolumeInfo
    let existingFilesPolicy: ExistingFilesPolicy

    func plan(sourceChanges: Changes, targetChanges: Changes, verify: Bool,
              checkpoint: (Int) throws -> Void) throws -> WorkPlan {
        var output = WorkPlan()
        var current: [String: FileStamp] = [:]
        var previous: [String: FileRecord] = [:]
        var selected = Set<String>()
        let renameRoots = Set(sourceChanges.paths.compactMap { $0.value & flagRenamed == 0 ? nil : $0.key })
        var targetDrift = Set<String>()
        var actualNames: [String: Set<String>] = [:]
        var scannedTargetNames: [String: String]?
        var targetNamesByDirectory: [String: [String: String]] = [:]
        var scanRoots: [String] = []
        let exclusions = SourceExclusions(source: source)

        func checked() throws {
            output.examined += 1
            if output.examined.isMultiple(of: 256) { try checkpoint(output.examined) }
        }

        func oldBelow(_ path: String) throws {
            try catalog.visitFiles(below: path) {
                guard !exclusions.contains($0.path) else { return }
                previous[$0.path] = $0
                selected.insert($0.path)
            }
        }

        func capture(_ path: String, _ stamp: FileStamp) throws {
            current[path] = stamp
            selected.insert(path)
            try checked()
        }

        func exactSource(_ path: String) throws -> FileStamp? {
            if sourceChanges.paths[path, default: 0] & flagRenamed != 0 {
                let parent = pathParent(path)
                if actualNames[parent] == nil {
                    do { actualNames[parent] = Set(try source.names(in: parent)) }
                    catch BackupError.io(_, _, let code) where code == ENOENT || code == ENOTDIR { actualNames[parent] = [] }
                }
                if actualNames[parent]?.contains(pathName(path)) != true { return nil }
            }
            return try source.entry(path)
        }

        func targetSpelling(_ path: String) throws -> String? {
            if path.isEmpty { return "" }
            if let scannedTargetNames { return scannedTargetNames[pathKey(path, caseSensitive: false)] }
            guard let parent = try targetSpelling(pathParent(path)) else { return nil }
            if targetNamesByDirectory[parent] == nil {
                do {
                    let names = try target.names(in: parent)
                    targetNamesByDirectory[parent] = Dictionary(names.map { (pathKey($0, caseSensitive: false), $0) },
                                                                uniquingKeysWith: { first, _ in first })
                } catch BackupError.io(_, _, let code) where code == ENOENT || code == ENOTDIR {
                    targetNamesByDirectory[parent] = [:]
                }
            }
            let key = pathKey(pathName(path), caseSensitive: false)
            return targetNamesByDirectory[parent]?[key].map { pathJoin(parent, $0) }
        }

        if sourceChanges.fullScan || verify {
            try source.scan(excluding: exclusions.contains, visit: capture)
            try oldBelow("")
        } else {
            for (path, flags) in sourceChanges.paths where !exclusions.contains(path) {
                let stamp = try exactSource(path)
                let wasDirectory = stamp == nil ? try catalog.file(path)?.source.kind == .directory : false
                let isSubtree = flags & flagSubtree != 0 ||
                    ((stamp?.kind == .directory || flags & flagDirectory != 0) &&
                     (flags & (flagRenamed | flagCreated | flagRemoved) != 0)) ||
                    wasDirectory
                if isSubtree {
                    scanRoots.append(path)
                } else {
                    if let stamp { try capture(path, stamp) } else { selected.insert(path) }
                }
            }
            var scanned = Set<String>()
            for root in scanRoots.sorted(by: { $0.count < $1.count }) {
                if hasAncestor(root, in: scanned) { continue }
                scanned.insert(root)
                if try exactSource(root) != nil { try source.scan(at: root, excluding: exclusions.contains, visit: capture) }
                try oldBelow(root)
            }
        }

        if targetChanges.fullScan || verify {
            var actual: [String: FileStamp] = [:]
            var managed = Set<String>()
            try target.scan(excludingControl: true, excluding: exclusions.contains) { path, stamp in
                actual[path] = stamp
                try checked()
            }
            if !volume.caseSensitive && existingFilesPolicy != .preserve {
                scannedTargetNames = Dictionary(actual.keys.map { (pathKey($0, caseSensitive: false), $0) },
                                                uniquingKeysWith: { first, _ in first })
            }
            try catalog.visitFiles { record in
                guard !exclusions.contains(record.path) else { return }
                managed.insert(record.path)
                let disk = actual.removeValue(forKey: record.path)
                if verify || !matches(record.target, disk) {
                    targetDrift.insert(record.path)
                    previous[record.path] = record
                    selected.insert(record.path)
                    if current[record.path] == nil, let stamp = try source.entry(record.path) {
                        try capture(record.path, stamp)
                    }
                }
            }
            output.unmanaged = actual.keys.filter { path in
                guard let companion = appleDoubleCompanion(path) else { return true }
                return companion != controlName && !managed.contains(companion) && actual[companion] == nil
            }.count
        } else {
            for (path, flags) in targetChanges.paths where !exclusions.contains(path) {
                if flags & (flagDirectory | flagSubtree) != 0 {
                    try catalog.visitFiles(below: path) { record in
                        guard !exclusions.contains(record.path) else { return }
                        if !matches(record.target, try target.entry(record.path)) {
                            targetDrift.insert(record.path)
                            previous[record.path] = record
                            selected.insert(record.path)
                            if current[record.path] == nil, let stamp = try source.entry(record.path) {
                                try capture(record.path, stamp)
                            }
                        }
                    }
                } else if let record = try catalog.file(path), !matches(record.target, try target.entry(path)) || flags & flagModified != 0 {
                    targetDrift.insert(path)
                    previous[path] = record
                    selected.insert(path)
                    if let stamp = try source.entry(path) { try capture(path, stamp) }
                } else if try catalog.file(path) == nil {
                    if let companion = appleDoubleCompanion(path) {
                        if companion == controlName { continue }
                        if try target.entry(companion) != nil { continue }
                    }
                    // Count foreign items on the next metadata reconciliation.
                    output.unmanaged = max(1, output.unmanaged ?? 0)
                }
            }
        }
        try source.checkRoot()
        try target.checkRoot()
        try checkpoint(output.examined)

        var removals: [String: Work] = [:]
        var updates: [String: Work] = [:]
        var typeChanges = Set<String>()
        for path in selected {
            let old = try previous[path] ?? catalog.file(path)
            if let stamp = current[path] {
                if stamp.kind == .unsupported || stamp.flags & UInt32(SF_DATALESS) != 0 {
                    output.problems[path] = "不支持的文件类型或尚未下载到 Mac"
                    continue
                }
                if path.split(separator: "/").first?.lowercased() == controlName {
                    output.problems[path] = "此名称由 Backup Genius 保留"
                    continue
                }
                if let old, old.source.kind != stamp.kind {
                    typeChanges.insert(path)
                    removals[path] = Work(kind: .remove, path: path, stamp: stamp, old: old)
                    updates[path] = Work(kind: .sync, path: path, stamp: stamp, old: nil, forceHash: true)
                } else {
                    let forced = targetDrift.contains(path) || sourceChanges.paths[path, default: 0] & flagModified != 0 || verify
                    if old?.source != stamp || forced {
                        updates[path] = Work(kind: .sync, path: path, stamp: stamp, old: old,
                                             forceHash: targetDrift.contains(path) || verify)
                    }
                }
            } else if let old {
                removals[path] = Work(kind: .remove, path: path, stamp: nil, old: old)
            }
        }

        let removedIDs = Dictionary(grouping: removals.values.compactMap { item -> FileRecord? in
            guard item.stamp == nil, let old = item.old, old.source.kind != .directory,
                  old.source.links == 1, !targetDrift.contains(item.path) else { return nil }
            return old
        }, by: { $0.source.identity })
        var moves: [Work] = []
        for (path, update) in updates where update.old == nil && !typeChanges.contains(path) {
            guard let stamp = update.stamp, stamp.links == 1, stamp.kind != .directory,
                  !verify, !update.forceHash, sourceChanges.paths[path, default: 0] & flagModified == 0,
                  hasAncestor(path, in: renameRoots), let records = removedIDs[stamp.identity],
                  records.count == 1, let old = records.first, removals[old.path] != nil,
                  stamp.sameContentIdentity(as: old.source),
                  !hasAncestor(old.path, in: typeChanges) else { continue }
            let caseOnly = !volume.caseSensitive &&
                pathKey(old.path, caseSensitive: false) == pathKey(path, caseSensitive: false)
            if let found = try target.entry(path),
               !(caseOnly && matches(old.target, found)) { continue }
            guard matches(old.target, try target.entry(old.path)) else { continue }
            moves.append(Work(kind: .move, path: path, stamp: stamp, old: old, from: old.path, caseOnly: caseOnly))
            updates.removeValue(forKey: path)
            removals.removeValue(forKey: old.path)
        }

        if !volume.caseSensitive {
            var names: [String: String] = [:]
            for path in current.keys {
                let key = pathKey(path, caseSensitive: false)
                if let other = names[key], other != path {
                    output.problems[other] = "大小写或 Unicode 文件名冲突：\(path)"
                    output.problems[path] = "大小写或 Unicode 文件名冲突：\(other)"
                } else {
                    names[key] = path
                }
            }
            for path in updates.keys {
                let key = pathKey(path, caseSensitive: false)
                if let other = try catalog.paths(folded: key).first(where: { $0 != path }) {
                    output.problems[path] = "目标文件名与 \(other) 冲突"
                    removals.removeValue(forKey: other)
                }
                guard existingFilesPolicy != .preserve, updates[path]?.old?.target == nil else { continue }
                if let actual = try targetSpelling(path) {
                    if actual == path {
                        updates[path]?.targetNameMatches = true
                    } else {
                        output.problems[path] = "目标文件名与 \(actual) 冲突"
                    }
                } else {
                    let parent = pathParent(path)
                    if let actualParent = try targetSpelling(parent), actualParent != parent {
                        output.problems[path] = "目标文件夹名称与 \(actualParent) 冲突"
                    }
                }
            }
        }

        let blocked = Set(output.problems.keys)
        func allowed(_ item: Work) -> Bool { !hasAncestor(item.path, in: blocked) }
        var directories: [Work] = []
        var files: [Work] = []
        for item in updates.values where allowed(item) {
            if item.stamp?.kind == .directory { directories.append(item) } else { files.append(item) }
        }
        var early: [Work] = []
        var late: [Work] = []
        for item in removals.values where allowed(item) {
            if hasAncestor(item.path, in: typeChanges) { early.append(item) } else { late.append(item) }
        }
        output.waves += byDepth(early, reverse: true)
        output.waves += byDepth(directories, reverse: false)
        output.waves.append(moves.filter(allowed).sorted(by: pathOrder))
        output.waves.append(files.sorted(by: pathOrder))
        output.waves += byDepth(late, reverse: true)
        output.waves.removeAll(where: \.isEmpty)
        output.existingWork = Set(output.waves.joined().compactMap {
            $0.old?.source.kind == .directory ? nil : $0.old?.path
        }).count
        return output
    }

    private func appleDoubleCompanion(_ path: String) -> String? {
        let name = pathName(path)
        guard volume.format == .exfat, name.hasPrefix("._"), name.count > 2 else { return nil }
        return pathJoin(pathParent(path), String(name.dropFirst(2)))
    }

    private func matches(_ a: FileStamp?, _ b: FileStamp?) -> Bool {
        if let a, let b { return a.matchesTarget(b, format: volume.format) }
        return a == nil && b == nil
    }

    private func byDepth(_ work: [Work], reverse: Bool) -> [[Work]] {
        let buckets = Dictionary(grouping: work, by: { $0.path.utf8.filter { $0 == 47 }.count })
        return buckets.keys.sorted(by: { reverse ? $0 > $1 : $0 < $1 })
            .map { buckets[$0]!.sorted(by: pathOrder) }
    }
}

private func hasAncestor(_ path: String, in values: Set<String>) -> Bool {
    var path = path
    while !path.isEmpty {
        if values.contains(path) { return true }
        path = pathParent(path)
    }
    return false
}

private func pathOrder(_ a: Work, _ b: Work) -> Bool { a.path < b.path }
