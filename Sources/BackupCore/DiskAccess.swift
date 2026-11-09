import Foundation
import DiskArbitration

public enum BackupDisk {
    public static func eject(_ mount: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let session = DASessionCreate(kCFAllocatorDefault),
                  let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, mount as CFURL) else {
                continuation.resume(throwing: BackupError.disconnected)
                return
            }
            let operation = Ejection(session: session, continuation: continuation)
            operation.begin(disk)
        }
    }
}

private final class Ejection {
    let session: DASession
    let queue = DispatchQueue(label: "backupgenius.eject", qos: .utility)
    let continuation: CheckedContinuation<Void, Error>

    init(session: DASession, continuation: CheckedContinuation<Void, Error>) {
        self.session = session
        self.continuation = continuation
    }

    func begin(_ disk: DADisk) {
        DASessionSetDispatchQueue(session, queue)
        let completion: DADiskUnmountCallback = { disk, dissenter, context in
            guard let context else { return }
            let operation = Unmanaged<Ejection>.fromOpaque(context).takeUnretainedValue()
            if let dissenter {
                operation.finish(dissenter)
                Unmanaged<Ejection>.fromOpaque(context).release()
                return
            }
            if let whole = DADiskCopyWholeDisk(disk) {
                DADiskEject(whole, DADiskEjectOptions(kDADiskEjectOptionDefault), { _, error, context in
                    guard let context else { return }
                    Unmanaged<Ejection>.fromOpaque(context).takeRetainedValue().finish(error)
                }, context)
            } else {
                operation.finish(nil)
                Unmanaged<Ejection>.fromOpaque(context).release()
            }
        }
        DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), completion,
                      Unmanaged.passRetained(self).toOpaque())
    }

    func finish(_ dissenter: DADissenter?) {
        DASessionSetDispatchQueue(session, nil)
        if let dissenter {
            let detail = DADissenterGetStatusString(dissenter) as String? ?? "请关闭正在使用硬盘的文件"
            continuation.resume(throwing: BackupError.message("无法推出硬盘：\(detail)"))
        } else {
            continuation.resume()
        }
    }
}
