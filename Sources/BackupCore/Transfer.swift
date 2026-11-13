import Foundation
import Darwin

// Transfers retain at most 128 KiB of replacement payload per file in a
// 128-item batch. Larger changes spill into an unlinked local scratch file.
final class PatchData: @unchecked Sendable {
    private struct Slice {
        let block: Int
        let length: Int
        let offset: Int64
        var data: Data?
    }

    private let scratch: Tree
    private var slices: [Slice] = []
    private var spill: FD?
    private(set) var bytes: Int64 = 0
    var blocks: [Int] { slices.map(\.block) }

    init(scratch: Tree) { self.scratch = scratch }

    func add(_ data: Data, block: Int) throws {
        if spill == nil, bytes + Int64(data.count) > IOProfile.retainedPatchLimit {
            let path = UUID().uuidString
            let file = try scratch.createFile(path)
            try scratch.remove(path)
            for i in slices.indices {
                try file.write(slices[i].data!, at: slices[i].offset)
                slices[i].data = nil
            }
            spill = file
        }
        if let spill { try spill.write(data, at: bytes) }
        let retained = spill == nil ? data.withUnsafeBytes { Data($0) } : nil
        slices.append(Slice(block: block, length: data.count, offset: bytes, data: retained))
        bytes += Int64(data.count)
    }

    private func runs(window: Int, splitFirst: Bool = false) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        while start < slices.count {
            var end = start + 1
            var length = slices[start].length
            if !splitFirst || start > 0 {
                while end < slices.count, slices[end].block == slices[end - 1].block + 1,
                      length + slices[end].length <= window {
                    length += slices[end].length
                    end += 1
                }
            }
            result.append(start..<end)
            start = end
        }
        return result
    }

    func writeRequests(window: Int) -> Int { runs(window: window).count }

    func apply(to file: FD, window: Int, onWrite: ((Int) -> Void)? = nil,
               afterFirstBlock: (() throws -> Void)? = nil) throws {
        for range in runs(window: window, splitFirst: afterFirstBlock != nil) {
            let first = slices[range.lowerBound], last = slices[range.upperBound - 1]
            let length = Int(last.offset - first.offset) + last.length
            let data: Data
            if let spill {
                data = try spill.readExact(at: first.offset, length: length)
            } else {
                var buffer = Data(capacity: length)
                for slice in slices[range] { buffer.append(slice.data!) }
                data = buffer
            }
            try file.write(data, at: Int64(first.block) * Int64(blockSize))
            onWrite?(data.count)
            if range.lowerBound == 0 { try afterFirstBlock?() }
        }
    }
}

struct Prepared: Sendable {
    enum Adoption: Sendable { case sharedDirectory, reusedFile, reusedLink, updatedEntry }

    var edit: DiskEdit?
    var patch: PatchData?
    var archive = false
    var oldHashes: Data?
    var sourceBytes: Int64 = 0
    var targetBytes: Int64 = 0
    var latestBytes: Int64 = 0
    var sourceReadRequests = 0
    var targetReadRequests = 0
    var latestWriteRequests = 0
    var adoption: Adoption?
}

struct Transfer: Sendable {
    let source: Tree
    let target: Tree
    let scratch: Tree
    let volume: VolumeInfo
    let existingFilesPolicy: ExistingFilesPolicy
    var profile = IOProfile(source: .unknown, target: .unknown)

    func prepare(_ work: Work, onIO: @escaping (Int, Int) -> Void) throws -> Prepared {
        switch work.kind {
        case .remove:
            return try prepareRemoval(work)
        case .move:
            return try prepareMove(work)
        case .sync:
            return try prepareSync(work, onIO: onIO)
        }
    }

    private var rich: Bool { volume.format == .apfs }

    private func activity(_ kind: Activity.Kind, _ path: String, detail: String? = nil, bytes: Int64 = 0) -> Activity {
        let nameNote = volume.format == .exfat && windowsNameProblem(path) ? "原名保留，需在 Mac 上打开或恢复" : nil
        let message = [detail, nameNote].compactMap { $0 }.joined(separator: "。")
        return Activity(date: Date(), kind: kind, path: path, detail: message.isEmpty ? nil : message, bytes: bytes)
    }

    private func prepareRemoval(_ work: Work) throws -> Prepared {
        guard let old = work.old else { return Prepared() }
        if old.sharedDirectory == true && !work.retireInstaller {
            return Prepared(edit: DiskEdit(method: .record, path: work.path))
        }
        let before = try target.entry(work.path)
        if work.retireInstaller, let before, before.kind != old.source.kind {
            throw BackupError.message("目标文件已被其他文件替换：\(work.path)")
        }
        guard old.target != nil || before == nil else {
            throw BackupError.message("目标位置已有未纳入备份的文件：\(work.path)")
        }
        if let before, before.kind == .unsupported {
            throw BackupError.message("无法归档目标中的特殊文件：\(work.path)")
        }
        var edit = DiskEdit(method: before == nil ? .record : .remove, path: work.path, before: before)
        edit.activity = activity(.deleted, work.path)
        let known = if let before, let oldStamp = old.target, oldStamp.matchesTarget(before, format: volume.format) {
            old.hashes
        } else {
            Optional<Data>.none
        }
        return Prepared(edit: edit, archive: before != nil || old.link != nil, oldHashes: known)
    }

    private func prepareMove(_ work: Work) throws -> Prepared {
        guard let old = work.old, let from = work.from, let stamp = work.stamp else {
            throw BackupError.message("缺少移动来源")
        }
        let before = try target.entry(from)
        if let before, let expected = old.target {
            guard before.matchesTarget(expected, format: volume.format) else { throw BackupError.unstable(from) }
        } else if before != nil || old.target != nil {
            throw BackupError.unstable(from)
        }
        var next = old
        next.path = work.path
        next.source = stamp
        let method: DiskEdit.Method = before == nil ? .record : (work.caseOnly ? .caseMove : .move)
        var edit = DiskEdit(method: method, path: work.path, from: from, before: before, next: next, staging: UUID())
        edit.activity = activity(.moved, work.path, detail: from)
        return Prepared(edit: edit)
    }

    private func prepareSync(_ work: Work, onIO: @escaping (Int, Int) -> Void) throws -> Prepared {
        guard let stamp = work.stamp, try source.entry(work.path) == stamp else { throw BackupError.unstable(work.path) }
        _ = try target.directory(pathParent(work.path))
        let before = try target.entry(work.path)
        let adopting = before != nil && work.old?.target == nil
        if adopting {
            guard existingFilesPolicy != .preserve else {
                throw BackupError.message("目标位置已有未纳入备份的文件：\(work.path)")
            }
            guard volume.caseSensitive || work.targetNameMatches else {
                throw BackupError.message("无法确认目标文件名一致，请重新检查：\(work.path)")
            }
        }
        if let before, before.kind != stamp.kind {
            throw BackupError.message("目标的文件类型已改变：\(work.path)")
        }
        switch stamp.kind {
        case .regular:
            return try prepareFile(work, stamp: stamp, before: before, adopting: adopting, onIO: onIO)
        case .directory, .symlink:
            return try prepareEntry(work, stamp: stamp, before: before, adopting: adopting)
        case .unsupported:
            throw BackupError.message("不支持的文件类型：\(work.path)")
        }
    }

    private func prepareEntry(_ work: Work, stamp: FileStamp, before: FileStamp?, adopting: Bool) throws -> Prepared {
        var attrs = try source.attributes(work.path, stamp: stamp, rich: true)
        attrs.windows = work.old?.attributes.windows
        let link = stamp.kind == .symlink ? try source.readLink(work.path) : nil
        if let link, work.old?.link == link {
            attrs.windowsLink = work.old?.attributes.windowsLink
            attrs.windowsLinkDirectory = work.old?.attributes.windowsLinkDirectory
        }
        guard try source.entry(work.path) == stamp else { throw BackupError.unstable(work.path) }
        var next = FileRecord(path: work.path, source: stamp, target: before, attributes: attrs, link: link)
        if adopting && stamp.kind == .directory {
            next.sharedDirectory = true
            var edit = DiskEdit(method: .record, path: work.path, before: before, next: next)
            if volume.format == .exfat && windowsNameProblem(work.path) {
                edit.activity = activity(.verified, work.path)
            }
            return Prepared(edit: edit, adoption: .sharedDirectory)
        }
        var edit = DiskEdit(method: .record, path: work.path, before: before, next: next)
        var version = false

        if let link, !rich, before == nil {
            if work.old?.link == link && work.old?.attributes == attrs && work.old?.source == stamp &&
                work.old?.target == nil { return Prepared() }
            version = work.old != nil && (work.old?.link != link || work.old?.attributes != attrs)
        } else if stamp.kind == .directory, let before {
            if work.old?.source == stamp && work.old?.attributes == attrs && !work.forceHash { return Prepared() }
            if work.old?.sharedDirectory == true {
                next.sharedDirectory = true
                edit.next = next
                return Prepared(edit: edit)
            }
            edit.method = .attributes
            edit.originalAttributes = try target.attributes(work.path, stamp: before, rich: rich)
            version = rich && work.old?.attributes.extended != attrs.extended
        } else {
            if let link, let before {
                let matches = try target.readLink(work.path) == link
                guard try target.entry(work.path) == before else { throw BackupError.unstable(work.path) }
                if matches && adopting {
                    edit.activity = activity(.verified, work.path, detail: "链接指向一致，已沿用硬盘上的链接")
                    return Prepared(edit: edit, adoption: .reusedLink)
                }
                if matches && (!rich || (work.old?.attributes == attrs && work.old?.target == before)) {
                    if work.old?.source == stamp && work.old?.target == before && work.old?.link == link &&
                        work.old?.attributes == attrs { return Prepared() }
                    return Prepared(edit: edit)
                }
                if adopting && existingFilesPolicy == .reuseIdentical {
                    throw BackupError.message("同名链接指向不同，已保留硬盘上的链接：\(work.path)")
                }
            }
            let staging = UUID()
            let path = staged(staging)
            do {
                if let link {
                    try target.createLink(link, at: path)
                    try target.applyLinkTime(attrs, at: path)
                } else {
                    try target.mkdir(path)
                    var writable = attrs
                    writable.mode |= 0o700
                    let directory = try target.directory(path)
                    try directory.apply(writable, rich: rich)
                    try directory.flush(directory: true)
                }
                next.target = try target.entry(path)
            } catch {
                try? target.removeOwnedTree(path)
                throw error
            }
            edit.method = .install
            edit.staging = staging
            edit.next = next
            version = before != nil
        }
        edit.activity = activity(work.old == nil && !adopting ? .added : .updated, work.path)
        return Prepared(edit: edit, archive: version, adoption: adopting ? .updatedEntry : nil)
    }

    private func prepareFile(_ work: Work, stamp: FileStamp, before: FileStamp?, adopting: Bool,
                             onIO: @escaping (Int, Int) -> Void) throws -> Prepared {
        let requireIdentical = adopting && existingFilesPolicy == .reuseIdentical
        let conflict = BackupError.message("同名文件内容不同，已保留硬盘上的副本：\(work.path)")
        if requireIdentical && before?.size != stamp.size { throw conflict }
        let input = try source.file(work.path)
        guard try input.stamp() == stamp else { throw BackupError.unstable(work.path) }
        var attrs = try input.attributes(stamp, rich: true)
        attrs.windows = work.old?.attributes.windows
        let oldFile = before != nil ? try target.file(work.path) : nil
        var result = Prepared()
        var base = Data()
        var originalAttrs: MacAttributes?
        if let before, let oldFile {
            guard try oldFile.stamp() == before else { throw BackupError.unstable(work.path) }
            if let old = work.old, let expected = old.target, expected.matchesTarget(before, format: volume.format),
               !work.forceHash {
                base = old.hashes
                originalAttrs = old.attributes
            } else {
                base = try oldFile.fileHashes(size: before.size, window: profile.targetWindow) {
                    result.targetBytes += Int64($0)
                    result.targetReadRequests += 1
                    onIO($0, 0)
                }
                if !adopting {
                    originalAttrs = try oldFile.attributes(before, rich: rich)
                    if !rich, var stored = work.old?.attributes {
                        stored.modified = before.modified
                        originalAttrs = stored
                    }
                }
            }
            guard try oldFile.stamp() == before else { throw BackupError.unstable(work.path) }
            result.oldHashes = base
        }

        let stageID = UUID()
        let temp = staged(stageID)
        var ownsTemp = false
        var keepTemp = false
        defer { if ownsTemp && !keepTemp { try? target.removeOwnedTree(temp) } }
        let newFile: FD?
        if before == nil {
            newFile = try target.createFile(temp)
            ownsTemp = true
        } else {
            newFile = nil
        }

        let patch = PatchData(scratch: scratch)
        var next = FileRecord(path: work.path, source: stamp, target: before, attributes: attrs)
        do {
            try input.readSequentially(size: stamp.size, window: profile.sourceWindow) { offset, data in
                result.sourceBytes += Int64(data.count)
                result.sourceReadRequests += 1
                for start in stride(from: 0, to: data.count, by: blockSize) {
                    let block = data[start..<min(start + blockSize, data.count)]
                    let hash = digest(block)
                    next.hashes.append(hash)
                    let index = Int(offset / Int64(blockSize)) + start / blockSize
                    if newFile == nil, base.blockHash(index) != hash {
                        if requireIdentical { throw conflict }
                        try patch.add(block, block: index)
                    }
                }
                if let newFile {
                    try newFile.write(data, at: offset)
                    result.latestBytes += Int64(data.count)
                    result.latestWriteRequests += 1
                }
                onIO(data.count, newFile == nil ? 0 : data.count)
            }
        } catch {
            if (try? input.stamp()) != stamp { throw BackupError.unstable(work.path) }
            throw error
        }
        guard try input.stamp() == stamp, try source.entry(work.path) == stamp else {
            throw BackupError.unstable(work.path)
        }

        var edit = DiskEdit(method: .record, path: work.path, before: before, originalAttributes: originalAttrs, next: next)
        let differs = before.map { $0.size != stamp.size } == true || patch.bytes > 0
        if adopting, let oldFile, let before {
            guard try oldFile.stamp() == before else { throw BackupError.unstable(work.path) }
            if differs {
                edit.originalAttributes = try oldFile.attributes(before, rich: true)
                result.adoption = .updatedEntry
            } else {
                // The existing file already contains the backup. Register its
                // observed stamp without rewriting its data or metadata.
                edit.activity = activity(.verified, work.path, detail: "内容一致，已沿用硬盘上的文件")
                result.adoption = .reusedFile
            }
        }
        if let newFile {
            try newFile.apply(attrs, rich: rich)
            try newFile.flush()
            next.target = try newFile.stamp()
            edit.method = .install
            edit.staging = stageID
        } else if differs, rich, let oldFile {
            try target.clone(oldFile, to: temp)
            ownsTemp = true
            let original = try target.file(temp)
            if fchmod(original.value, mode_t(try original.stamp().mode | 0o200)) != 0 {
                throw BackupError.posix("无法准备克隆文件", work.path)
            }
            let clone = try target.file(temp, writable: true)
            try patch.apply(to: clone, window: profile.targetWindow, onWrite: { onIO(0, $0) })
            try clone.resize(stamp.size)
            try clone.apply(attrs, rich: true)
            try clone.flush()
            result.latestBytes += patch.bytes
            result.latestWriteRequests += patch.writeRequests(window: profile.targetWindow)
            next.target = try clone.stamp()
            edit.method = .install
            edit.staging = stageID
            result.archive = true
        } else if differs, let before {
            // Reject read-only files and system metadata before publishing a
            // prepared transaction. The transaction checks the stamp again.
            let writable = try target.file(work.path, writable: true)
            guard try writable.stamp() == before else { throw BackupError.unstable(work.path) }
            edit.method = .patch
            edit.rollbackBlocks = patch.blocks
            result.patch = patch
            result.latestBytes += patch.bytes
            result.archive = true
        } else if let originalAttrs, let before {
            // An exFAT timestamp can round differently than the original nanosecond value.
            let drift = work.old?.target.map { !$0.matchesTarget(before, format: volume.format) } ?? true
            let attrsChanged = work.old?.attributes != attrs
            if attrsChanged || drift {
                edit.method = .attributes
                result.archive = originalAttrs.mode != attrs.mode || originalAttrs.extended != attrs.extended ||
                    originalAttrs.acl != attrs.acl
            } else if work.old?.source == stamp && work.old?.target == before {
                return result
            }
        }

        if edit.method != .record {
            edit.activity = activity(work.old == nil && !adopting ? .added : .updated, work.path, bytes: result.latestBytes)
        }
        edit.next = next
        result.edit = edit
        keepTemp = true
        return result
    }
}

extension Repository {
    func archive(_ edit: DiskEdit, old: FileRecord?, knownHashes: Data?, writer: PackWriter,
                 onRead: (Int) -> Void) throws -> ArchivedVersion? {
        guard let stamp = edit.before else {
            guard let old, let link = old.link else { return nil }
            return ArchivedVersion(item: historyItem(edit, size: 0), kind: .symlink,
                                   attributes: old.attributes, link: link)
        }
        let attrs = try edit.originalAttributes ?? targetAttributesForArchive(edit, stamp: stamp, old: old)
        var version = ArchivedVersion(item: historyItem(edit, size: stamp.kind == .regular ? stamp.size : 0),
                                      kind: stamp.kind, attributes: attrs)
        switch stamp.kind {
        case .regular:
            let input = try tree.file(edit.path)
            guard try input.stamp() == stamp else { throw BackupError.unstable(edit.path) }
            if rich, edit.method != .patch {
                try tree.clone(input, to: cloned(version.item.id))
                version.clone = version.item.id
                version.hashes = try knownHashes ?? input.fileHashes(size: stamp.size, onRead: onRead)
                try tree.file(cloned(version.item.id)).flush()
            } else {
                var offset: Int64 = 0
                var index = 0
                while offset < stamp.size {
                    let expected = knownHashes?.blockHash(index)
                    if let expected, try writer.contains(expected) {
                        version.hashes.append(expected)
                        offset += min(Int64(blockSize), stamp.size - offset)
                    } else {
                        let data = try input.readExact(at: offset, length: Int(min(Int64(blockSize), stamp.size - offset)))
                        onRead(data.count)
                        let hash = digest(data)
                        if let expected, hash != expected {
                            // Cached destination evidence was stale. Replan with fresh target hashes.
                            throw BackupError.unstable(edit.path)
                        }
                        try writer.save(data, hash: hash)
                        version.hashes.append(hash)
                        offset += Int64(data.count)
                    }
                    index += 1
                }
            }
            guard try input.stamp() == stamp else { throw BackupError.unstable(edit.path) }
        case .symlink:
            version.link = try tree.readLink(edit.path)
        case .directory:
            break
        case .unsupported:
            throw BackupError.message("不支持的旧文件类型：\(edit.path)")
        }
        return version
    }

    private func targetAttributesForArchive(_ edit: DiskEdit, stamp: FileStamp, old: FileRecord?) throws -> MacAttributes {
        if !rich, var attrs = old?.attributes {
            if old?.target?.matchesTarget(stamp, format: volume.format) != true { attrs.modified = stamp.modified }
            return attrs
        }
        return try tree.attributes(edit.path, stamp: stamp, rich: rich)
    }

    private func historyItem(_ edit: DiskEdit, size: Int64) -> HistoryItem {
        HistoryItem(id: UUID(), date: Date(), path: edit.path, size: size,
                    reason: edit.method == .remove || edit.activity?.kind == .deleted ? .deleted : .updated)
    }
}
