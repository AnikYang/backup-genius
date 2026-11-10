import Foundation
import CoreServices

final class EventInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Changes()
    private var waitingForHistory: Bool
    private let scope: String
    private let excludeControl: Bool
    private let notify: @Sendable () -> Void

    init(scope: String, excludeControl: Bool, replay: Bool, notify: @escaping @Sendable () -> Void) {
        self.scope = scope
        self.excludeControl = excludeControl
        self.waitingForHistory = replay
        self.notify = notify
    }

    func receive(count: Int, paths: UnsafeMutableRawPointer, flags: UnsafePointer<UInt32>,
                 ids: UnsafePointer<UInt64>) {
        let array = paths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        let changed = lock.withLock {
            var notify = false
            for i in 0..<count {
                let flag = flags[i]
                if flag & UInt32(kFSEventStreamEventFlagEventIdsWrapped) != 0 {
                    pending.resetCursor = true
                    pending.cursor = 0
                }
                if !pending.resetCursor { pending.cursor = max(pending.cursor, ids[i]) }
                if flag & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
                    waitingForHistory = false
                    continue
                }
                let loss = UInt32(kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
                                  kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped)
                if flag & loss != 0 {
                    pending.fullScan = true
                    notify = true
                    continue
                }
                guard let raw = array[i], let input = String(validatingCString: raw) else {
                    pending.fullScan = true
                    notify = true
                    continue
                }
                let path = String(input.drop(while: { $0 == "/" }))
                let relative: String
                if scope.isEmpty {
                    relative = path
                } else if path == scope {
                    relative = ""
                } else if path.hasPrefix(scope + "/") {
                    relative = String(path.dropFirst(scope.count + 1))
                } else if flag & flagSubtree != 0 && (path.isEmpty || scope.hasPrefix(path + "/")) {
                    pending.fullScan = true
                    notify = true
                    continue
                } else {
                    continue
                }
                if excludeControl && isBackupControl(relative) { continue }
                if relative.isEmpty {
                    if flag & (flagSubtree | flagRenamed | flagRemoved) != 0 {
                        pending.fullScan = true
                        notify = true
                    }
                } else if pending.paths.count < 32768 {
                    pending.paths[relative, default: 0] |= flag
                    notify = true
                } else {
                    pending.fullScan = true
                    notify = true
                }
            }
            return notify
        }
        if changed { notify() }
    }

    func take() -> Changes {
        lock.withLock {
            var changes = pending
            if waitingForHistory { changes.fullScan = true }
            pending = Changes()
            return changes
        }
    }
}

final class EventMonitor {
    let identity: String
    let url: URL
    let device: dev_t
    private let inbox: EventInbox
    private let stream: FSEventStreamRef
    private let queue = DispatchQueue(label: "backupgenius.filesystem-events", qos: .utility)

    static func uuid(for device: dev_t) -> String? {
        guard let uuid = FSEventsCopyUUIDForDevice(device) else { return nil }
        return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String?
    }

    static func current(for device: dev_t) -> UInt64 {
        FSEventsGetLastEventIdForDeviceBeforeTime(device, CFAbsoluteTimeGetCurrent())
    }

    init(tree: Tree, since: UInt64, excludeControl: Bool, notify: @escaping @Sendable () -> Void) throws {
        identity = tree.identity
        url = tree.url
        device = tree.device
        let scope = try VolumeLocation(tree.root).relative(tree.url)
        let inbox = EventInbox(scope: scope, excludeControl: excludeControl, replay: since > 0, notify: notify)
        self.inbox = inbox
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(inbox).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        var flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot |
                           kFSEventStreamCreateFlagNoDefer)
        if excludeControl { flags |= UInt32(kFSEventStreamCreateFlagIgnoreSelf) }
        guard let stream = FSEventStreamCreateRelativeToDevice(kCFAllocatorDefault, { _, context, count, paths, flags, ids in
            guard let context else { return }
            Unmanaged<EventInbox>.fromOpaque(context).takeUnretainedValue()
                .receive(count: count, paths: paths, flags: flags, ids: ids)
        }, &context, tree.device, [scope] as CFArray, since > 0 ? since : UInt64.max, 0.25, flags) else {
            throw BackupError.message("无法监听文件变化")
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            throw BackupError.message("无法启动文件变化监听")
        }
    }

    func drain(flush: Bool) -> Changes {
        if flush { FSEventStreamFlushSync(stream) }
        return inbox.take()
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        queue.sync {}
    }
}
