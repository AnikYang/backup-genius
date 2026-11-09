import Foundation
import Darwin
import CryptoKit
import CBackup
import DiskArbitration
import IOKit

let controlName = ".backup-genius"
let blockSize = 64 * 1024
let digestSize = 32

func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

extension Data {
    func blockHash(_ index: Int) -> Data? {
        guard index >= 0, index < count / digestSize else { return nil }
        let start = index * digestSize
        return self.subdata(in: start..<(start + digestSize))
    }
}

func pathParent(_ path: String) -> String {
    path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
}

func pathName(_ path: String) -> String {
    path.lastIndex(of: "/").map { String(path[path.index(after: $0)...]) } ?? path
}

func pathJoin(_ parent: String, _ name: String) -> String {
    parent.isEmpty ? name : "\(parent)/\(name)"
}

func relativePath(_ url: URL, in root: URL) -> String? {
    let path = url.standardizedFileURL.path
    let base = root.standardizedFileURL.path
    if path == base { return "" }
    let prefix = base == "/" ? "/" : base + "/"
    guard path.hasPrefix(prefix) else { return nil }
    return String(path.dropFirst(prefix.count))
}

func pathComponents(_ path: String) throws -> [Substring] {
    if path.isEmpty { return [] }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
        throw BackupError.message("无效的相对路径：\(path)")
    }
    return parts
}

func userPath(_ path: String) throws {
    let parts = try pathComponents(path)
    guard let first = parts.first, first.lowercased() != controlName else {
        throw BackupError.message("此名称由 Backup Genius 保留：\(path)")
    }
}

func windowsNameProblem(_ path: String) -> Bool {
    let invalid = CharacterSet(charactersIn: "<>:\"\\|?*").union(.controlCharacters)
    return path.split(separator: "/").contains { name in
        if name.hasSuffix(".") || name.hasSuffix(" ") || name.utf16.count > 255 ||
            name.unicodeScalars.contains(where: { invalid.contains($0) }) { return true }
        let base = name.split(separator: ".", omittingEmptySubsequences: false).first?.uppercased() ?? ""
        if ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"].contains(base) { return true }
        return ["COM", "LPT"].contains(String(base.prefix(3))) && base.count == 4 &&
            "123456789¹²³".contains(base.suffix(1))
    }
}

func pathKey(_ path: String, caseSensitive: Bool) -> String {
    let canonical = path.precomposedStringWithCanonicalMapping
    return caseSensitive ? canonical : canonical.lowercased()
}

final class FD: @unchecked Sendable {
    let value: Int32
    let label: String

    init(_ value: Int32, _ label: String, action: String = "无法打开") throws {
        guard value >= 0 else { throw BackupError.posix(action, label) }
        self.value = value
        self.label = label
    }

    deinit { Darwin.close(value) }

    func rawStat() throws -> stat {
        var info = stat()
        guard fstat(value, &info) == 0 else { throw BackupError.posix("无法检查", label) }
        return info
    }

    func stamp() throws -> FileStamp { FileStamp(try rawStat()) }

    func read(at offset: Int64, length: Int) throws -> Data {
        var data = Data(count: length)
        let count = try data.withUnsafeMutableBytes { buffer -> Int in
            var total = 0
            while total < length {
                let read = pread(value, buffer.baseAddress!.advanced(by: total), length - total, offset + Int64(total))
                if read == 0 { break }
                if read < 0 {
                    if errno == EINTR { continue }
                    throw BackupError.posix("无法读取", label)
                }
                total += read
            }
            return total
        }
        if count != length { data.count = count }
        return data
    }

    func readExact(at offset: Int64, length: Int) throws -> Data {
        let data = try read(at: offset, length: length)
        guard data.count == length else { throw BackupError.message("文件长度意外改变：\(label)") }
        return data
    }

    func write(_ data: Data, at offset: Int64) throws {
        try data.withUnsafeBytes { buffer in
            var total = 0
            while total < buffer.count {
                let wrote = pwrite(value, buffer.baseAddress!.advanced(by: total), buffer.count - total, offset + Int64(total))
                if wrote <= 0 {
                    if wrote < 0 && errno == EINTR { continue }
                    if wrote == 0 { throw BackupError.io("无法写入", label, EIO) }
                    throw BackupError.posix("无法写入", label)
                }
                total += wrote
            }
        }
    }

    func resize(_ size: Int64) throws {
        guard ftruncate(value, size) == 0 else { throw BackupError.posix("无法调整文件长度", label) }
    }

    func flush(full: Bool = false, directory: Bool = false) throws {
        if bg_flush(value, full ? 1 : 0) != 0 {
            let code = errno
            if directory && (code == EINVAL || code == ENOTSUP || code == EBADF) { return }
            throw BackupError.io("无法确认写入", label, code)
        }
    }

    func fileHashes(size: Int64, onRead: (Int) -> Void = { _ in }) throws -> Data {
        var result = Data()
        var offset: Int64 = 0
        while offset < size {
            let data = try readExact(at: offset, length: Int(min(Int64(blockSize), size - offset)))
            onRead(data.count)
            result.append(digest(data))
            offset += Int64(data.count)
        }
        return result
    }

    func attributes(_ stamp: FileStamp, rich: Bool) throws -> MacAttributes {
        var result = MacAttributes(mode: stamp.mode, modified: stamp.modified, birth: stamp.birth)
        guard rich else { return result }
        var attributeBytes = 0
        for name in try attributeNames() {
            let length = fgetxattr(value, name, nil, 0, 0, 0)
            if length < 0 && errno == ENOATTR { continue }
            guard length >= 0 else { throw BackupError.posix("无法读取扩展属性", label) }
            attributeBytes += length
            guard attributeBytes <= 2 * 1024 * 1024 else {
                throw BackupError.message("扩展属性超过 2 MiB，请单独备份此文件：\(label)")
            }
            var data = Data(count: length)
            let count = data.withUnsafeMutableBytes { fgetxattr(value, name, $0.baseAddress, length, 0, 0) }
            guard count == length else { throw BackupError.unstable(label) }
            result.extended[name] = data
        }
        if let acl = acl_get_fd_np(value, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            if acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0, let info = acl_to_text(acl, nil) {
                result.acl = String(cString: info)
                acl_free(info)
            }
        } else if errno != ENOENT && errno != ENOTSUP && errno != EINVAL {
            throw BackupError.posix("无法读取访问权限", label)
        }
        return result
    }

    private func attributeNames() throws -> [String] {
        let size = flistxattr(value, nil, 0, 0)
        if size < 0 && (errno == ENOTSUP || errno == EINVAL) { return [] }
        guard size >= 0 else { throw BackupError.posix("无法列出扩展属性", label) }
        guard size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        let count = buffer.withUnsafeMutableBytes {
            flistxattr(value, $0.baseAddress?.assumingMemoryBound(to: CChar.self), size, 0)
        }
        guard count >= 0 else { throw BackupError.posix("无法列出扩展属性", label) }
        return buffer.prefix(count).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    func apply(_ attrs: MacAttributes, rich: Bool) throws {
        if rich {
            for name in try attributeNames() where attrs.extended[name] == nil {
                guard fremovexattr(value, name, 0) == 0 || errno == ENOATTR else {
                    throw BackupError.posix("无法更新扩展属性", label)
                }
            }
            for (name, bytes) in attrs.extended {
                if bytes.withUnsafeBytes({ fsetxattr(value, name, $0.baseAddress, $0.count, 0, 0) }) != 0 {
                    throw BackupError.posix("无法保存扩展属性", label)
                }
            }
            if let acl = attrs.acl.flatMap({ acl_from_text($0) }) ?? acl_init(0) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                if acl_set_fd_np(value, acl, ACL_TYPE_EXTENDED) != 0 && errno != ENOTSUP {
                    throw BackupError.posix("无法设置访问权限", label)
                }
            }
            if bg_set_birth_time(value, attrs.birth.posix) != 0 && errno != ENOTSUP && errno != EINVAL {
                throw BackupError.posix("无法设置创建时间", label)
            }
            if fchmod(value, mode_t(attrs.mode & 0o777)) != 0 {
                throw BackupError.posix("无法设置文件模式", label)
            }
        }
        let times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), attrs.modified.posix]
        guard futimens(value, times) == 0 else { throw BackupError.posix("无法设置修改时间", label) }
    }
}

final class Tree: @unchecked Sendable {
    let url: URL
    let root: FD
    let device: dev_t
    let identity: String

    init(_ url: URL) throws {
        self.url = url
        root = try FD(Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), url.path)
        let info = try root.rawStat()
        device = info.st_dev
        identity = FileStamp(info).identity
    }

    func checkRoot() throws {
        var raw = stat()
        guard lstat(url.path, &raw) == 0, raw.st_dev == device, try root.rawStat().st_dev == device,
              FileStamp(raw).kind == .directory, FileStamp(raw).identity == identity else {
            throw BackupError.message("文件夹已移动或断开：\(url.path)")
        }
    }

    func directory(_ path: String) throws -> FD {
        var current = root
        for component in try pathComponents(path) {
            let child = try FD(openat(current.value, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), path)
            guard try child.rawStat().st_dev == device else {
                throw BackupError.message("无法跨入另一卷：\(path)")
            }
            current = child
        }
        return current
    }

    func parent(_ path: String) throws -> (FD, String) {
        _ = try pathComponents(path)
        let name = pathName(path)
        guard !name.isEmpty else { throw BackupError.message("根目录不可更改") }
        return (try directory(pathParent(path)), name)
    }

    func entry(_ path: String) throws -> FileStamp? {
        if path.isEmpty { return try root.stamp() }
        let parts: (FD, String)
        do { parts = try parent(path) } catch BackupError.io(_, _, let code) where code == ENOENT || code == ENOTDIR {
            return nil
        }
        return try entry(in: parts.0, name: parts.1, path: path)
    }

    private func entry(in dir: FD, name: String, path: String) throws -> FileStamp? {
        var raw = stat()
        if fstatat(dir.value, name, &raw, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw BackupError.posix("无法检查", path)
        }
        guard raw.st_dev == device else { throw BackupError.message("无法跨入另一卷：\(path)") }
        return FileStamp(raw)
    }

    func file(_ path: String, writable: Bool = false) throws -> FD {
        let (dir, name) = try parent(path)
        let file = try FD(openat(dir.value, name, (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC), path)
        let stat = try file.rawStat()
        guard FileStamp(stat).kind == .regular, stat.st_dev == device else {
            throw BackupError.message("需要普通文件：\(path)")
        }
        return file
    }

    func attributes(_ path: String, stamp: FileStamp, rich: Bool) throws -> MacAttributes {
        switch stamp.kind {
        case .regular:
            return try file(path).attributes(stamp, rich: rich)
        case .directory:
            return try directory(path).attributes(stamp, rich: rich)
        case .symlink:
            let (dir, name) = try parent(path)
            let link = try FD(openat(dir.value, name, O_RDONLY | O_SYMLINK | O_CLOEXEC), path)
            guard try link.stamp().kind == .symlink else { throw BackupError.unstable(path) }
            return try link.attributes(stamp, rich: rich)
        case .unsupported:
            throw BackupError.message("不支持的文件类型：\(path)")
        }
    }

    func createFile(_ path: String) throws -> FD {
        let (dir, name) = try parent(path)
        return try FD(openat(dir.value, name, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600), path,
                      action: "无法创建")
    }

    func mkdir(_ path: String, existing: Bool = false) throws {
        let (dir, name) = try parent(path)
        if mkdirat(dir.value, name, 0o700) != 0 {
            if existing && errno == EEXIST && (try? entry(in: dir, name: name, path: path)?.kind) == .directory { return }
            throw BackupError.posix("无法创建文件夹", path)
        }
    }

    func makeParents(of path: String) throws {
        var partial = ""
        for component in try pathComponents(pathParent(path)) {
            partial = pathJoin(partial, String(component))
            try mkdir(partial, existing: true)
        }
    }

    func names(in path: String) throws -> [String] {
        let dir = try directory(path)
        return try names(dir)
    }

    private func names(_ dir: FD) throws -> [String] {
        let cursor = openat(dir.value, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard cursor >= 0 else { throw BackupError.posix("无法扫描", dir.label) }
        guard let stream = fdopendir(cursor) else {
            let error = BackupError.posix("无法扫描", dir.label)
            Darwin.close(cursor)
            throw error
        }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let item = readdir(stream) else {
                if errno != 0 { throw BackupError.posix("扫描中断", dir.label) }
                return result
            }
            let name = withUnsafeBytes(of: &item.pointee.d_name) { bytes in
                String(bytes: bytes.prefix(Int(item.pointee.d_namlen)), encoding: .utf8)
            }
            guard let name else { throw BackupError.message("文件名无法识别：\(dir.label)") }
            if name != "." && name != ".." { result.append(name) }
        }
    }

    func scan(at path: String = "", excludingControl: Bool = false, visit: (String, FileStamp) throws -> Void) throws {
        if !path.isEmpty {
            guard let stamp = try entry(path) else { return }
            try visit(path, stamp)
            guard stamp.kind == .directory else { return }
        }
        func walk(_ dir: FD, _ prefix: String) throws {
            for name in try names(dir) {
                if excludingControl && prefix.isEmpty && name.lowercased() == controlName { continue }
                let child = pathJoin(prefix, name)
                guard let stamp = try entry(in: dir, name: name, path: child) else { continue }
                try visit(child, stamp)
                if stamp.kind == .directory {
                    let fd = try FD(openat(dir.value, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC), child)
                    let raw = try fd.rawStat()
                    guard raw.st_dev == device, FileStamp(raw).identity == stamp.identity else {
                        throw BackupError.unstable(child)
                    }
                    try walk(fd, child)
                }
            }
        }
        try walk(directory(path), path)
    }

    func readLink(_ path: String) throws -> Data {
        let (dir, name) = try parent(path)
        var data = Data(count: Int(PATH_MAX))
        let count = data.withUnsafeMutableBytes {
            readlinkat(dir.value, name, $0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count)
        }
        guard count >= 0 && count < data.count else { throw BackupError.posix("无法读取符号链接", path) }
        data.count = count
        return data
    }

    func createLink(_ target: Data, at path: String) throws {
        guard !target.isEmpty, target.count < Int(PATH_MAX), !target.contains(0) else {
            throw BackupError.message("无法恢复符号链接：\(path)")
        }
        let (dir, name) = try parent(path)
        var string = target
        string.append(0)
        let rc = string.withUnsafeBytes { symlinkat($0.baseAddress!.assumingMemoryBound(to: CChar.self), dir.value, name) }
        guard rc == 0 else { throw BackupError.posix("无法创建符号链接", path) }
    }

    func applyLinkTime(_ attrs: MacAttributes, at path: String) throws {
        let (dir, name) = try parent(path)
        let times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), attrs.modified.posix]
        guard utimensat(dir.value, name, times, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw BackupError.posix("无法设置链接修改时间", path)
        }
    }

    func rename(_ from: String, to: String, replacing: Bool = false) throws {
        let (src, old) = try parent(from)
        let (dst, new) = try parent(to)
        if replacing {
            guard renameat(src.value, old, dst.value, new) == 0 else { throw BackupError.posix("无法移动到", to) }
            return
        }
        if bg_rename_exclusive(src.value, old, dst.value, new) == 0 { return }
        guard errno == ENOTSUP else { throw BackupError.posix("无法移动到", to) }
        // The macOS exFAT driver implements rename but does not implement
        // RENAME_EXCL. Recheck the destination with the same parent descriptor.
        guard try entry(in: dst, name: new, path: to) == nil else {
            throw BackupError.io("目标位置已有其他文件", to, EEXIST)
        }
        guard renameat(src.value, old, dst.value, new) == 0 else { throw BackupError.posix("无法移动到", to) }
    }

    func clone(_ source: FD, to path: String) throws {
        let (dir, name) = try parent(path)
        guard fclonefileat(source.value, dir.value, name, UInt32(CLONE_NOOWNERCOPY | CLONE_ACL)) == 0 else {
            throw BackupError.posix("无法克隆", path)
        }
    }

    @discardableResult
    func remove(_ path: String, directory: Bool = false, keepNonEmpty: Bool = false) throws -> Bool {
        let (dir, name) = try parent(path)
        if unlinkat(dir.value, name, directory ? AT_REMOVEDIR : 0) != 0 {
            if errno == ENOENT { return false }
            if keepNonEmpty && (errno == ENOTEMPTY || errno == EEXIST) { return false }
            throw BackupError.posix("无法移除", path)
        }
        return true
    }

    func removeOwnedTree(_ path: String) throws {
        guard let stamp = try entry(path) else { return }
        if stamp.kind == .directory {
            for child in try names(in: path) { try removeOwnedTree(pathJoin(path, child)) }
        }
        try remove(path, directory: stamp.kind == .directory)
    }

    func readDocument<T: Decodable>(_ type: T.Type, from path: String) throws -> T {
        let fd = try file(path)
        let size = try fd.stamp().size
        guard size >= 0 && size <= 64 * 1024 * 1024 else { throw BackupError.message("备份记录大小异常：\(path)") }
        return try JSONDecoder().decode(type, from: fd.readExact(at: 0, length: Int(size)))
    }

    func writeDocument<T: Encodable>(_ value: T, at path: String, replacing: Bool = false) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 64 * 1024 * 1024 else { throw BackupError.message("备份记录超过大小限制：\(path)") }
        let temp = pathJoin(pathParent(path), ".write-\(UUID().uuidString)")
        let fd = try createFile(temp)
        do {
            try fd.write(data, at: 0)
            try fd.flush(full: true)
            try rename(temp, to: path, replacing: replacing)
            try directory(pathParent(path)).flush(directory: true)
            try fd.flush(full: true)
        } catch {
            _ = try? remove(temp)
            throw error
        }
    }
}

struct VolumeLocation {
    let mount: URL
    let formatName: String

    init(_ fd: FD) throws {
        var info = statfs()
        guard fstatfs(fd.value, &info) == 0 else { throw BackupError.posix("无法检查卷", fd.label) }
        let mountPath = withUnsafeBytes(of: &info.f_mntonname) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        mount = URL(fileURLWithPath: mountPath, isDirectory: true)
        formatName = withUnsafeBytes(of: &info.f_fstypename) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    func relative(_ url: URL) throws -> String {
        if let path = relativePath(url, in: mount) { return path }
        // The writable system volume exposes /Users through a firmlink.
        if mount.path == "/System/Volumes/Data" {
            return String(url.path.drop(while: { $0 == "/" }))
        }
        throw BackupError.message("无法解析卷内路径：\(url.path)")
    }
}

public extension VolumeInfo {
    static func inspect(_ folder: URL) throws -> Self {
        let root = try Tree(folder.resolvingSymlinksInPath())
        let location = try VolumeLocation(root.root)
        guard let format = DiskFormat(rawValue: location.formatName.lowercased()) else {
            throw BackupError.message("请选择 APFS 或 exFAT 硬盘")
        }
        let values = try location.mount.resourceValues(forKeys: [
            .volumeUUIDStringKey, .volumeNameKey, .volumeIsInternalKey, .volumeIsReadOnlyKey,
            .volumeAvailableCapacityKey, .volumeTotalCapacityKey, .volumeSupportsCaseSensitiveNamesKey,
        ])
        guard values.volumeIsReadOnly != true else { throw BackupError.message("此硬盘为只读") }
        let session = DASessionCreate(kCFAllocatorDefault)
        let disk = session.flatMap { DADiskCreateFromVolumePath(kCFAllocatorDefault, $0, location.mount as CFURL) }
        let description = disk.flatMap { DADiskCopyDescription($0) } as? [String: Any]
        let mediaUUID = description?[kDADiskDescriptionMediaUUIDKey as String] as? UUID
        let diskUUID = description?[kDADiskDescriptionVolumeUUIDKey as String]
        let volumeUUID: String? = diskUUID.flatMap { value in
            guard CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() else { return nil }
            return CFUUIDCreateString(kCFAllocatorDefault, (value as! CFUUID)) as String
        }
        let identifier = values.volumeUUIDString ?? volumeUUID ?? mediaUUID?.uuidString ?? ""
        let mountedUnderVolumes = location.mount.path.hasPrefix("/Volumes/")
        let isExternal: Bool
        if let deviceInternal = description?[kDADiskDescriptionDeviceInternalKey as String] as? Bool {
            isExternal = !deviceInternal
        } else {
            // FSKit can leave the device attributes unavailable to a sandboxed
            // client. The system data volume is never mounted below /Volumes.
            isExternal = values.volumeIsInternal == false ||
                (mountedUnderVolumes && (values.volumeIsInternal == nil || format == .exfat))
        }
        var solidState = false
        if let disk {
            let media = DADiskCopyIOMedia(disk)
            if media != 0 {
                defer { IOObjectRelease(media) }
                let property = IORegistryEntrySearchCFProperty(media, kIOServicePlane,
                    "Device Characteristics" as CFString, kCFAllocatorDefault,
                    IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively))
                let attributes = property as? [String: Any]
                solidState = attributes?["Medium Type"] as? String == "Solid State"
            }
        }
        return Self(name: values.volumeName ?? location.mount.lastPathComponent, mount: location.mount,
                    identifier: identifier, format: format, availableBytes: Int64(values.volumeAvailableCapacity ?? 0),
                    totalBytes: Int64(values.volumeTotalCapacity ?? 0),
                    caseSensitive: values.volumeSupportsCaseSensitiveNames ?? false,
                    isExternal: isExternal, isSolidState: solidState)
    }
}
