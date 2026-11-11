import Foundation
import DiskArbitration
import IOKit

public enum StorageMedium: String, Codable, Sendable, CaseIterable {
    case hdd, ssd, unknown

    public var name: String {
        switch self {
        case .hdd: "HDD"
        case .ssd: "SSD"
        case .unknown: "类型未知"
        }
    }
}

public struct StorageDeviceInfo: Sendable, Equatable {
    public let identifier: String
    public let medium: StorageMedium

    static func inspect(_ tree: Tree) -> Self {
        guard let location = try? VolumeLocation(tree.root) else { return .init(identifier: "", medium: .unknown) }
        let identifier = (try? location.mount.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString ?? ""
        let session = DASessionCreate(kCFAllocatorDefault)
        let disk = session.flatMap { DADiskCreateFromVolumePath(kCFAllocatorDefault, $0, location.mount as CFURL) }
        return inspect(disk, identifier: identifier)
    }

    static func inspect(_ disk: DADisk?, identifier: String) -> Self {
        guard let disk else { return .init(identifier: identifier, medium: .unknown) }
        let media = DADiskCopyIOMedia(disk)
        guard media != 0 else { return .init(identifier: identifier, medium: .unknown) }
        defer { IOObjectRelease(media) }
        let property = IORegistryEntrySearchCFProperty(media, kIOServicePlane, "Device Characteristics" as CFString,
            kCFAllocatorDefault, IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively))
        let type = (property as? [String: Any])?["Medium Type"] as? String
        let medium: StorageMedium
        switch type {
        case "Rotational": medium = .hdd
        case "Solid State": medium = .ssd
        default: medium = .unknown
        }
        return .init(identifier: identifier, medium: medium)
    }
}

public struct IOProfile: Sendable, Equatable {
    public static let batchSize = 128
    public static let bufferLimit = 64 * 1024 * 1024
    static let retainedPatchLimit = 128 * 1024

    public let workers: Int
    public let sourceWindow: Int
    public let targetWindow: Int

    public init(source: StorageMedium, target: StorageMedium) {
        workers = source == .ssd && target == .ssd ? 4 : 1
        sourceWindow = Self.window(source)
        targetWindow = Self.window(target)
    }

    static func window(_ medium: StorageMedium) -> Int { (medium == .ssd ? 1 : 4) * 1024 * 1024 }

    // Preparation holds at most one read window per worker. A batch can also
    // retain small dirty blocks and one window for ordered patch publication.
    var bufferBudget: Int {
        Self.batchSize * Self.retainedPatchLimit + workers * max(sourceWindow, targetWindow) + targetWindow
    }
}
