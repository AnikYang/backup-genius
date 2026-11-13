import Foundation
import Darwin
import DiskArbitration
import IOKit
import CBackup

public struct DiskHealthReport: Sendable {
    public let model: String
    public let connection: String
    public let medium: StorageMedium
    public let health: String
    public let warning: Bool
    public let temperature: Int?
    public let percentageUsed: Int?
    public let recording: String
    public let checked: Date
}

public struct DiskSpeedReport: Sendable {
    public let readBytesPerSecond: Double
    public let writeBytesPerSecond: Double
    public let randomReadMilliseconds: Double
    public let bytes: Int64
    public let checked: Date
}

public enum DiskDiagnostics {
    public static func health(at url: URL) async throws -> DiskHealthReport {
        try await Task.detached(priority: .utility) {
            let access = Scope(url)
            return try withExtendedLifetime(access) {
                let volume = try VolumeInfo.inspect(url)
                let session = DASessionCreate(kCFAllocatorDefault)
                let disk = session.flatMap { DADiskCreateFromVolumePath(kCFAllocatorDefault, $0, volume.mount as CFURL) }
                let media = disk.map { DADiskCopyIOMedia($0) } ?? 0
                defer { if media != 0 { IOObjectRelease(media) } }
                func property(_ key: String) -> [String: Any] {
                    guard media != 0 else { return [:] }
                    return IORegistryEntrySearchCFProperty(media, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                        IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)) as? [String: Any] ?? [:]
                }
                let device = property("Device Characteristics")
                let protocolInfo = property("Protocol Characteristics")
                let health = media == 0 ? BGDiskHealth(status: 0, temperature_c: -999, percentage_used: -1, zoned: 0) : bg_disk_health(media)
                let medium = volume.device.medium
                return DiskHealthReport(model: device["Product Name"] as? String ?? volume.name,
                    connection: protocolInfo["Physical Interconnect"] as? String ?? "系统未提供",
                    medium: medium,
                    health: health.status == 2 ? "设备报告健康警告" : (health.status == 1 ? "设备未报告健康警告" : "无法读取 S.M.A.R.T.，设备、硬盘盒或系统权限未提供访问"),
                    warning: health.status == 2,
                    temperature: health.temperature_c > -100 ? Int(health.temperature_c) : nil,
                    percentageUsed: health.percentage_used >= 0 ? Int(health.percentage_used) : nil,
                    recording: medium == .ssd ? "SSD 不适用" : (health.zoned > 0 ? "设备报告 SMR 分区能力" : "无法确认 SMR / CMR，需按准确型号查询厂商规格"),
                    checked: .now)
            }
        }.value
    }

    // A bounded scratch-file test. Never reads or overwrites any user file.
    public static func measure(at url: URL) async throws -> DiskSpeedReport {
        try await Task.detached(priority: .utility) {
            let access = Scope(url)
            return try withExtendedLifetime(access) {
                let tree = try Tree(url.resolvingSymlinksInPath())
                let volume = try VolumeInfo.inspect(url)
                let bytes = 64 * 1024 * 1024
                guard volume.availableBytes > Int64(bytes * 3) else { throw BackupError.message("可用空间不足，测速需要至少 192 MB") }
                let path = ".backup-genius-speed-\(UUID().uuidString)"
                let file = try tree.createFile(path)
                defer { try? tree.remove(path) }
                _ = fcntl(file.value, F_NOCACHE, 1)
                var buffer = Data(count: 1024 * 1024)
                buffer.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
                let begin = ProcessInfo.processInfo.systemUptime
                for offset in stride(from: 0, to: bytes, by: buffer.count) {
                    try Task.checkCancellation()
                    try tree.checkRoot()
                    try file.write(buffer, at: Int64(offset))
                }
                try file.flush(full: true)
                let writeTime = ProcessInfo.processInfo.systemUptime - begin
                let readBegin = ProcessInfo.processInfo.systemUptime
                for offset in stride(from: 0, to: bytes, by: buffer.count) {
                    try Task.checkCancellation()
                    let read = try file.readExact(at: Int64(offset), length: buffer.count)
                    guard read == buffer else { throw BackupError.message("测速文件读回校验失败") }
                }
                let readTime = ProcessInfo.processInfo.systemUptime - readBegin
                let randomBegin = ProcessInfo.processInfo.systemUptime
                for i in 0..<64 {
                    try Task.checkCancellation()
                    let offset = ((i * 7919) % (bytes / 4096)) * 4096
                    _ = try file.readExact(at: Int64(offset), length: 4096)
                }
                let latency = (ProcessInfo.processInfo.systemUptime - randomBegin) * 1000 / 64
                return DiskSpeedReport(readBytesPerSecond: Double(bytes) / max(readTime, 0.000001),
                                       writeBytesPerSecond: Double(bytes) / max(writeTime, 0.000001),
                                       randomReadMilliseconds: latency, bytes: Int64(bytes), checked: .now)
            }
        }.value
    }
}
