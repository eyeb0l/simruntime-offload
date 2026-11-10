import Foundation

/// The advisory lock that keeps two operations from changing mounts and links
/// at once.
///
/// launchd starts the agent for every mount, including the ones a sync makes
/// itself, so overlapping runs are expected. `sync` gives way when the lock is
/// held; `eject` holds it for its whole run so that the agent cannot re-attach
/// a runtime that has just been released. The kernel drops the lock if the
/// holder dies, so it can never be left stale.
public final class StateLock {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Takes the lock, or throws `SyncError.alreadyRunning` at once if another
    /// process holds it.
    public static func acquire(paths: Paths) throws -> StateLock {
        try FileManager.default.createDirectory(atPath: paths.stateDirectory, withIntermediateDirectories: true)
        let descriptor = open("\(paths.stateDirectory)/sync.flock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SyncError.alreadyRunning }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw SyncError.alreadyRunning
        }
        return StateLock(descriptor: descriptor)
    }

    public func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
