import XCTest
@testable import SoundBridgeHost

// MARK: - Publishing a file other processes read
//
// Phase 6A, Bug #1's driver-side half. The control file and `device-state.json`
// are read by processes the Host does not coordinate with: the driver polls the
// control file about once a second and treats its contents as the complete
// desired device set, and the App watches the state file.
//
// The 1.2.0 writer created a temporary file and then called `removeItem`
// followed by `moveItem`. Between those two calls the path does not exist. A
// driver that read inside that window saw an empty device list, concluded the
// Host wanted nothing, and removed every proxy it had published — after which
// nothing re-published them, which is why the SoundBridge devices stayed gone
// until the App was relaunched.
//
// These tests run real readers against real replacements. The concurrency one
// is the actual claim: there is no instant at which a reader can see the path
// absent.

final class AtomicFileWriterTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SoundBridgeAtomicTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandbox {
            try? FileManager.default.removeItem(at: sandbox)
        }
        try super.tearDownWithError()
    }

    private func path(_ name: String) -> String {
        sandbox.appendingPathComponent(name).path
    }

    // MARK: - The basic contract

    func testCreatesTheFileWhenItDidNotExist() throws {
        let target = path("devices.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))

        XCTAssertTrue(AtomicFileWriter.replace(at: target, with: Data("LG|uid-1".utf8)))

        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "LG|uid-1")
    }

    func testReplacesExistingContents() throws {
        let target = path("devices.txt")
        try "old|uid-0".write(toFile: target, atomically: false, encoding: .utf8)

        XCTAssertTrue(AtomicFileWriter.replace(at: target, with: Data("new|uid-1\nPHL|uid-2".utf8)))

        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "new|uid-1\nPHL|uid-2")
    }

    func testWritesEmptyDataAsAnEmptyFile() throws {
        // An empty control file is a meaningful state ("no devices"), distinct
        // from an unreadable one. It must be publishable.
        let target = path("devices.txt")
        try "something".write(toFile: target, atomically: false, encoding: .utf8)

        XCTAssertTrue(AtomicFileWriter.replace(at: target, with: Data()))

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target)).count, 0)
    }

    func testLeavesNoTemporaryFileBehind() throws {
        let target = path("devices.txt")
        _ = AtomicFileWriter.replace(at: target, with: Data("one".utf8))
        _ = AtomicFileWriter.replace(at: target, with: Data("two".utf8))

        let contents = try FileManager.default.contentsOfDirectory(atPath: sandbox.path)
        XCTAssertEqual(contents, ["devices.txt"], "a stray .tmp would be a leak the driver could read")
    }

    func testThePublishedFileIsNotWorldWritable() throws {
        let target = path("device-state.json")
        _ = AtomicFileWriter.replace(at: target, with: Data("{}".utf8))

        let attributes = try FileManager.default.attributesOfItem(atPath: target)
        let mode = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue

        XCTAssertNotEqual(mode & 0o200, 0, "the owner must be able to write it")
        XCTAssertEqual(mode & 0o022, 0, "another user must not be able to rewrite the Host's state")
    }

    func testAFailedWriteReportsFailureInsteadOfCrashing() {
        // A directory that does not exist. The Host must keep running and log it;
        // the previous contents, had there been any, stay in place.
        let missing = sandbox.appendingPathComponent("no-such-dir", isDirectory: true)
            .appendingPathComponent("devices.txt").path

        XCTAssertFalse(AtomicFileWriter.replace(at: missing, with: Data("x".utf8)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
    }

    func testAFailureDoesNotDisturbTheExistingFile() throws {
        let directory = sandbox.appendingPathComponent("readonly", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let target = directory.appendingPathComponent("devices.txt").path
        try "published".write(toFile: target, atomically: false, encoding: .utf8)

        // Readable but not writable from here on: the writer cannot create its
        // temporary file, so the replacement must fail without touching the
        // published contents.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        // Root can write anywhere; this assertion only means something for a
        // normal user account, which is how the Host runs.
        guard getuid() != 0 else { return }

        XCTAssertFalse(AtomicFileWriter.replace(at: target, with: Data("replacement".utf8)))
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "published")
    }

    // MARK: - 符号链接父目录（/tmp 的形状）

    func testPublishesIntoTheRealTmpDirectory() throws {
        // Host 的生产控制文件就在 `/tmp` 下，而 `/tmp` 是 `private/tmp` 的符号链接。
        // Foundation 的 resolvingSymlinksInPath() 会把它规范化回 `/tmp`（不解析），
        // 于是 `open(..., O_DIRECTORY|O_NOFOLLOW)` 以 ENOTDIR 失败，控制文件永远
        // 发布不出去：Host 停在 degraded、驱动创建 0 个代理设备、整条音频链路无声，
        // 而失败是静默的。
        //
        // 这条用例必须打在真实 `/tmp` 上：放到临时沙箱目录里是抓不到的，那里的
        // 符号链接会被 Foundation 正常解析，旧实现也能成功。
        try XCTSkipUnless((try? FileManager.default.destinationOfSymbolicLink(atPath: "/tmp")) != nil,
                          "/tmp 不是符号链接，这条回归不适用")
        let target = "/tmp/SoundBridgeAtomicWriterTest-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: target) }

        // 目标不存在与目标已存在是两条不同的 rename 前置分支，都要走通。
        XCTAssertTrue(AtomicFileWriter.replace(at: target, with: Data("one|uid-1".utf8)))
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "one|uid-1")
        XCTAssertTrue(AtomicFileWriter.replace(at: target, with: Data("two|uid-2".utf8)))
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "two|uid-2")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: "/tmp")
            .filter { $0.hasPrefix(".SoundBridgeAtomicWriterTest-") }, [],
                       "发布成功且不留 .tmp 暂存")
    }

    func testPublishesThroughASymlinkedParentDirectory() throws {
        // 父目录是普通符号链接（非 /tmp 特例）时，发布也必须落在真实目录里。
        let real = sandbox.appendingPathComponent("real-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = sandbox.appendingPathComponent("tmp-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let target = link.appendingPathComponent("soundbridge-devices.txt").path

        XCTAssertTrue(AtomicFileWriter.replace(at: target, with: Data("one|uid-1".utf8)))
        XCTAssertTrue(AtomicFileWriter.replace(at: target, with: Data("two|uid-2".utf8)))

        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "two|uid-2")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: real.path),
                       ["soundbridge-devices.txt"], "内容必须落在真实目录里，且不留 .tmp")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sandbox.path).sorted(),
                       ["real-tmp", "tmp-link"])
    }

    // MARK: - Session 和有序发布

    func testRegistryPublishesSessionMetadataWithoutChangingLegacyDeviceLines() throws {
        let control = path("control.txt")
        let state = URL(fileURLWithPath: path("state.json"))
        let registry = DeviceRegistry(controlFilePath: control, deviceStateURL: state, notify: { _ in })
        registry.writeControlFile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: control))

        let session = UUID()
        registry.beginSession(session)
        let device = PhysicalDevice(
            id: 1, name: "Display", uid: "physical-uid", manufacturer: "Test",
            transportType: 0, isOutput: true, validationPassed: true,
            validationNote: nil, isFixedVolume: true
        )
        registry.update([device])
        let first = try String(contentsOfFile: control, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertEqual(first, ["#SB-CONTROL 1 \(session.uuidString) 1 \(getuid()) 1", "Display|physical-uid"])
        // 旧解析器只处理含竖线的行。
        XCTAssertEqual(first.filter { $0.contains("|") }, ["Display|physical-uid"])
        registry.writeControlFile()
        XCTAssertTrue(try String(contentsOfFile: control, encoding: .utf8)
            .hasPrefix("#SB-CONTROL 1 \(session.uuidString) 2 "))

        let decoded = try JSONDecoder().decode(HostDeviceStatePayload.self, from: Data(contentsOf: state))
        XCTAssertEqual(decoded.sessionID, session.uuidString)
        XCTAssertEqual(decoded.protocolVersion, 1)
        XCTAssertEqual(decoded.revision, 1)
    }

    func testRegistryRetainsPreviousSnapshotWhenControlWriteFails() throws {
        guard getuid() != 0 else { throw XCTSkip("目录权限测试需要非 root 用户") }
        let controlDirectory = sandbox.appendingPathComponent("control-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
        let control = controlDirectory.appendingPathComponent("devices.txt")
        let state = sandbox.appendingPathComponent("state.json")
        let registry = DeviceRegistry(controlFilePath: control.path, deviceStateURL: state, notify: { _ in })
        registry.beginSession(UUID())
        func device(_ uid: String) -> PhysicalDevice {
            PhysicalDevice(id: 1, name: uid, uid: uid, manufacturer: "Fake", transportType: 0,
                           isOutput: true, validationPassed: true, validationNote: nil, isFixedVolume: true)
        }
        XCTAssertTrue(registry.update([device("old")]))
        let oldControl = try Data(contentsOf: control)
        let oldState = try Data(contentsOf: state)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: controlDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: controlDirectory.path) }
        XCTAssertFalse(registry.update([device("new")]))
        XCTAssertEqual(registry.devices.map(\.uid), ["old"])
        XCTAssertEqual(try Data(contentsOf: control), oldControl)
        XCTAssertEqual(try Data(contentsOf: state), oldState)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: controlDirectory.path)
        XCTAssertTrue(registry.update([device("new")]))
        XCTAssertEqual(registry.devices.map(\.uid), ["new"])
        let snapshot = try JSONDecoder().decode(HostDeviceStatePayload.self, from: Data(contentsOf: state))
        XCTAssertEqual(snapshot.devices.map(\.uid), ["new"])
    }

    func testStateWriteRetriesLatestSnapshotAfterTemporaryFailure() throws {
        let directory = sandbox.appendingPathComponent("missing-state-directory", isDirectory: true)
        let state = directory.appendingPathComponent("state.json")
        let control = path("control.txt")
        var retries: [(TimeInterval, () -> Void)] = []
        var stateNotifications = 0
        let registry = DeviceRegistry(controlFilePath: control, deviceStateURL: state,
                                      scheduleStateRetry: { retries.append(($0, $1)) },
                                      notify: { if $0 == "com.soundbridge.device-state-changed" { stateNotifications += 1 } })
        let session = UUID()
        registry.beginSession(session)
        func device(_ uid: String) -> PhysicalDevice {
            PhysicalDevice(id: 1, name: uid, uid: uid, manufacturer: "Fake", transportType: 0,
                           isOutput: true, validationPassed: true, validationNote: nil, isFixedVolume: true)
        }

        XCTAssertTrue(registry.update([device("old")]))
        XCTAssertEqual(retries.map(\.0), [1])
        retries.removeFirst().1()
        XCTAssertEqual(retries.map(\.0), [2])
        XCTAssertTrue(registry.update([device("new")]))
        XCTAssertEqual(retries.count, 1, "重复失败不应排队多个重试")
        XCTAssertEqual(registry.devices.map(\.uid), ["new"])
        XCTAssertTrue(try String(contentsOfFile: control, encoding: .utf8).contains("new|new"))
        XCTAssertEqual(stateNotifications, 0)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        retries.removeFirst().1()
        let snapshot = try JSONDecoder().decode(HostDeviceStatePayload.self, from: Data(contentsOf: state))
        XCTAssertEqual(snapshot.devices.map(\.uid), ["new"])
        XCTAssertEqual(snapshot.sessionID, session.uuidString)
        XCTAssertEqual(snapshot.revision, 4)
        XCTAssertEqual(stateNotifications, 1)
        XCTAssertTrue(retries.isEmpty)
    }

    func testSuccessfulStateWriteInvalidatesOlderScheduledRetry() throws {
        let directory = sandbox.appendingPathComponent("state-directory", isDirectory: true)
        let state = directory.appendingPathComponent("state.json")
        var retries: [(TimeInterval, () -> Void)] = []
        var notifications = 0
        let registry = DeviceRegistry(controlFilePath: path("control.txt"), deviceStateURL: state,
                                      scheduleStateRetry: { retries.append(($0, $1)) },
                                      notify: { if $0 == "com.soundbridge.device-state-changed" { notifications += 1 } })
        registry.beginSession(UUID())
        registry.writeDeviceStateFile()
        XCTAssertEqual(retries.count, 1)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        registry.writeDeviceStateFile()
        let published = try Data(contentsOf: state)
        XCTAssertEqual(notifications, 1)
        retries.removeFirst().1()
        XCTAssertEqual(try Data(contentsOf: state), published)
        XCTAssertEqual(notifications, 1)
    }

    func testEndingSessionInvalidatesScheduledAndDirectPublications() throws {
        let directory = sandbox.appendingPathComponent("state-directory", isDirectory: true)
        let state = directory.appendingPathComponent("state.json")
        let control = path("control.txt")
        var retries: [(TimeInterval, () -> Void)] = []
        let registry = DeviceRegistry(controlFilePath: control, deviceStateURL: state,
                                      scheduleStateRetry: { retries.append(($0, $1)) }, notify: { _ in })
        registry.beginSession(UUID())
        XCTAssertTrue(registry.update([]))
        let publishedControl = try Data(contentsOf: URL(fileURLWithPath: control))
        XCTAssertEqual(retries.count, 1)
        registry.endSession()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        retries.removeFirst().1()
        registry.writeDeviceStateFile()
        XCTAssertFalse(registry.writeControlFile())
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: control)), publishedControl)
        XCTAssertTrue(retries.isEmpty)
    }

    func testRegistrySerializesConcurrentStateRevisions() throws {
        let state = URL(fileURLWithPath: path("state.json"))
        let snapshots = SnapshotRecorder()
        let registry = DeviceRegistry(controlFilePath: path("control.txt"), deviceStateURL: state, notify: { name in
            if name == "com.soundbridge.device-state-changed", let data = try? Data(contentsOf: state) {
                snapshots.append(data)
            }
        })
        let session = UUID()
        registry.beginSession(session)
        DispatchQueue.concurrentPerform(iterations: 40) { _ in registry.writeDeviceStateFile() }
        let decoded = try snapshots.values.map { try JSONDecoder().decode(HostDeviceStatePayload.self, from: $0) }
        XCTAssertEqual(decoded.count, 40)
        XCTAssertEqual(decoded.compactMap(\.revision), (1...40).map(UInt64.init))
        XCTAssertTrue(decoded.allSatisfy { $0.sessionID == session.uuidString })
    }

    // MARK: - The claim the fix exists for

    func testConcurrentWritersPublishOnlyCompleteSnapshots() throws {
        let target = path("concurrent.json")
        let payloads = (0..<4).map { Data(repeating: UInt8(65 + $0), count: 64 * 1024) }
        XCTAssertTrue(AtomicFileWriter.replace(at: target, with: payloads[0]))
        let failures = TestCounter()
        let invalidReads = TestCounter()
        let group = DispatchGroup()
        for payload in payloads {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                for _ in 0..<40 {
                    if !AtomicFileWriter.replace(at: target, with: payload) {
                        failures.increment()
                    }
                }
                group.leave()
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while group.wait(timeout: .now()) == .timedOut && Date() < deadline {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: target)),
                  payloads.contains(data) else {
                invalidReads.increment()
                continue
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        XCTAssertEqual(failures.value, 0)
        XCTAssertEqual(invalidReads.value, 0)
        XCTAssertTrue(payloads.contains(try Data(contentsOf: URL(fileURLWithPath: target))))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sandbox.path), ["concurrent.json"])
    }

    func testAReaderNeverObservesThePathMissingDuringReplacement() throws {
        let target = path("devices.txt")
        XCTAssertTrue(AtomicFileWriter.replace(at: target, with: Data("value-0".utf8)))

        let stop = TestFlag()
        let missing = TestCounter()
        let empty = TestCounter()

        let writer = expectation(description: "writer finished")
        DispatchQueue.global(qos: .userInitiated).async {
            for i in 1...400 {
                _ = AtomicFileWriter.replace(at: target, with: Data("value-\(i)".utf8))
            }
            stop.set()
            writer.fulfill()
        }

        // Read as the driver would: as fast as the loop allows, for the whole
        // duration of the replacement run.
        while !stop.isSet {
            let exists = FileManager.default.fileExists(atPath: target)
            if !exists {
                missing.increment()
            } else if let data = try? Data(contentsOf: URL(fileURLWithPath: target)), data.isEmpty {
                empty.increment()
            }
        }

        wait(for: [writer], timeout: 30)

        XCTAssertEqual(missing.value, 0,
                       "the path was absent \(missing.value) times during replacement; the driver would read that as 'remove every proxy'")
        XCTAssertEqual(empty.value, 0, "a reader saw a half-written body")
    }
}

// MARK: - Helpers

private final class SnapshotRecorder {
    private let lock = NSLock()
    private var storage: [Data] = []

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(data)
    }

    var values: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Small lock-backed flag so the reader loop and the writer can run at the same
/// time without importing a concurrency library.
private final class TestFlag {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

private final class TestCounter {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
