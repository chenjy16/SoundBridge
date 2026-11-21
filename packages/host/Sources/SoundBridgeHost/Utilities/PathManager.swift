import Foundation

enum PathManagerError: Error {
    case directoryCreationFailed(String)
    case invalidPath
}

struct PathManager {
    private static let fileManager = FileManager.default

    static let appSupportDir: URL = {
        let url = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("SoundBridge")
        return url
    }()

    static let logsDir: URL = {
        let url = fileManager.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Logs/SoundBridge")
        return url
    }()

    /// Mapping path identity (Batch 1): the owning UID is part of the file name
    /// so mappings from different users can never collide. Must match the
    /// driver's `SharedMemoryPath()` and the App's EQController path.
    static func sharedMemoryPath(uid: String, ownerUID: uid_t = getuid()) -> String {
        let safeUID = sanitizeUID(uid)
        return "/tmp/soundbridge-\(ownerUID)-\(safeUID)"
    }

    static var controlFilePath: String {
        return "/tmp/soundbridge-devices.txt"
    }

    static func logFilePath(name: String) -> URL {
        return logsDir.appendingPathComponent("\(name).log")
    }

    static func ensureDirectories() throws {
        try createDirectoryIfNeeded(appSupportDir)
        try createDirectoryIfNeeded(logsDir)
    }

    private static func createDirectoryIfNeeded(_ url: URL) throws {
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw PathManagerError.invalidPath
            }
            return
        }

        do {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw PathManagerError.directoryCreationFailed(url.path)
        }
    }

    private static func sanitizeUID(_ uid: String) -> String {
        return uid
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }
}
