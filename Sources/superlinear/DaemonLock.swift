import Foundation

/// Keeps a second daemon from running against the same state. Two daemons
/// would each start agents from the same queue and overwrite each other's
/// saves.
///
/// The lock is an advisory `flock` on a file beside the state, held for the
/// life of the process; the kernel releases it however the process ends. The
/// descriptor is close-on-exec, so agents the daemon launches do not inherit it
/// and keep it held after the daemon exits.
enum DaemonLock {
    enum Outcome: Equatable {
        case acquired
        /// Another process holds the lock. Its pid, when it recorded one.
        case held(by: Int32?)
    }

    static func acquire(path: String) -> Outcome {
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return .held(by: nil) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let holder = readPid(fd)
            close(fd)
            return .held(by: holder)
        }
        // Record our pid for the message a second daemon prints. The
        // descriptor stays open, and so the lock held, until the process ends.
        ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        return .acquired
    }

    private static func readPid(_ fd: Int32) -> Int32? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        let text = String(decoding: buffer.prefix(count), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Int32(text)
    }
}
