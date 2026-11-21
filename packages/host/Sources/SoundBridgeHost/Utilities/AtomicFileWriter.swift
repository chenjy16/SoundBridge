import Darwin
import Foundation
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "AtomicFile")

/// Replace a file's contents without ever leaving its path absent.
///
/// Both files the Host publishes are read by other processes at their own pace:
/// the driver polls the control file about once a second, and the App watches
/// `device-state.json`. The 1.2.0 implementation wrote a temporary file and then
/// called `removeItem` followed by `moveItem`, which leaves a window in which
/// the path does not exist. A driver that read inside that window concluded the
/// Host wanted zero devices and removed every proxy it had published — the field
/// failure where the SoundBridge devices disappeared after `coreaudiod`
/// restarted and never came back, because nothing ever re-published them.
///
/// `rename(2)` is atomic within one filesystem: a reader sees either the old
/// file or the new one, never a missing path and never a half-written body.
/// `fsync` before rename flushes the staged file. Directory sync is attempted
/// after rename; failure then cannot undo or make the visible replacement absent.
///
/// This lives in its own type rather than as a private helper because it is the
/// fix, and a fix that can only be verified by reasoning about it is a fix that
/// will regress. `AtomicFileWriterTests` runs real readers against it.
enum AtomicFileWriter {

    enum PublicationResult: Equatable {
        case notPublished
        case published
        /// rename 已成功；不能把目录同步失败解释为旧文件仍在。
        case publishedDurabilityUncertain(Int32)

        var wasPublished: Bool {
            if case .notPublished = self { return false }
            return true
        }
    }

    /// 测试在独立目录中注入交错和系统调用失败；生产使用默认实现。
    struct Hooks {
        var afterStaging: () -> Void = {}
        var syncFile: (Int32) -> Int32 = { fsync($0) }
        var syncDirectory: (Int32) -> Int32 = { fsync($0) }
        var renameFile: (Int32, String, String) -> Int32 = { directory, source, target in
            source.withCString { sourceName in
                target.withCString { targetName in renameat(directory, sourceName, directory, targetName) }
            }
        }
        var removeStaging: (Int32, String) -> Int32 = { directory, name in
            name.withCString { unlinkat(directory, $0, 0) }
        }
    }

    /// 返回值表示 rename 是否发生；目录同步失败不会撤销已可见的发布。
    @discardableResult
    static func replace(at path: String, with data: Data) -> Bool {
        replaceDetailed(at: path, with: data).wasPublished
    }

    static func replaceDetailed(at path: String, with data: Data, hooks: Hooks = Hooks()) -> PublicationResult {
        let url = URL(fileURLWithPath: path)
        let target = url.lastPathComponent
        guard !target.isEmpty, target != ".", target != ".." else { return .notPublished }
        let originalDirectory = url.deletingLastPathComponent().path
        // 只解析父目录，不跟随目标文件，且必须用 realpath(3) 而不是 Foundation：
        // /tmp 在 macOS 上是 private/tmp 的符号链接，resolvingSymlinksInPath()
        // 会把它原样返回。未解析的父目录加上 O_NOFOLLOW，让 open 直接以 ENOTDIR
        // 失败，于是控制文件永远发布不出去——Host 停在 degraded、驱动创建 0 个
        // 代理设备、整条音频链路无声，而失败是静默的（见符号链接父目录的用例）。
        guard let resolvedDirectory = canonicalDirectory(originalDirectory) else { return .notPublished }
        let directory = open(resolvedDirectory, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { return .notPublished }
        defer { close(directory) }

        var openedDirectory = stat()
        var currentDirectory = stat()
        guard fstat(directory, &openedDirectory) == 0,
              stat(originalDirectory, &currentDirectory) == 0,
              (openedDirectory.st_mode & S_IFMT) == S_IFDIR,
              openedDirectory.st_dev == currentDirectory.st_dev,
              openedDirectory.st_ino == currentDirectory.st_ino else { return .notPublished }

        // 每次发布使用独立 inode；发布顺序仍由调用者负责串行化。
        let staging = ".\(target).tmp.\(UUID().uuidString)"
        let fd = staging.withCString {
            openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o644)
        }
        guard fd >= 0 else { return .notPublished }
        var renamed = false
        defer {
            if !renamed && hooks.removeStaging(directory, staging) != 0 && errno != ENOENT {
                logger.error("Failed to remove staging file \(staging, privacy: .public) (errno \(errno))")
            }
        }

        var wroteEverything = true
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, base.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                if written <= 0 { wroteEverything = false; break }
                offset += written
            }
        }
        if wroteEverything { wroteEverything = hooks.syncFile(fd) == 0 }
        if close(fd) != 0 { wroteEverything = false }
        guard wroteEverything else { return .notPublished }
        hooks.afterStaging()

        var destination = stat()
        let targetStatus = target.withCString { fstatat(directory, $0, &destination, AT_SYMLINK_NOFOLLOW) }
        guard (targetStatus == 0 && (destination.st_mode & S_IFMT) == S_IFREG) ||
                (targetStatus != 0 && errno == ENOENT),
              stat(originalDirectory, &currentDirectory) == 0,
              openedDirectory.st_dev == currentDirectory.st_dev,
              openedDirectory.st_ino == currentDirectory.st_ino else { return .notPublished }
        guard hooks.renameFile(directory, staging, target) == 0 else { return .notPublished }
        renamed = true
        guard hooks.syncDirectory(directory) == 0 else {
            let code = errno
            logger.error("Published \(path, privacy: .public), but directory sync failed (errno \(code))")
            return .publishedDurabilityUncertain(code)
        }
        return .published
    }

    /// 用 `realpath(3)` 解析父目录。
    ///
    /// Foundation 的 `resolvingSymlinksInPath()` 不保证解析 `/tmp`，而 `/tmp`
    /// 正是符号链接。父目录未解析时 `O_NOFOLLOW` 会让 `open(..., O_DIRECTORY)`
    /// 以 ENOTDIR 失败，控制文件就永远写不出去。解析之后 `O_NOFOLLOW` 才有意义：
    /// 拿到的描述符一定是真实目录，而不是一个可在校验后被替换的链接；调用方随后
    /// 仍以 `stat` 的 dev/ino 交叉校验它就是要写的那个目录。
    private static func canonicalDirectory(_ path: String) -> String? {
        return path.withCString { raw -> String? in
            guard let resolved = realpath(raw, nil) else { return nil }
            defer { free(UnsafeMutableRawPointer(resolved)) }
            return String(cString: resolved)
        }
    }
}
