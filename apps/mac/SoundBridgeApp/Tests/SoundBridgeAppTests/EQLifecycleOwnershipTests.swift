import XCTest
import Darwin
import CSoundBridgeAudio
@testable import SoundBridgeApp

// MARK: - Who owns the EQ writer
//
// Gate 3's Defect A was an ownership bug, not an EQ bug: `EQController` was a
// `@StateObject` inside `MenuBarView`, so the writer was created the first time
// the popover rendered. Launch → play audio → never open the menu bar left the
// Host's new mapping at `eq_sequence = 0` with an all-zero snapshot while
// `UserDefaults` held the user's real values.
//
// The tests below are about that ownership, and they read the *file the Host
// publishes* rather than a mock: `SharedMemoryFixture` builds the same inode,
// session marker and admission epoch the Host builds, and `rf_load_eq_snapshot_safe`
// is the reader the Host uses. `eq_sequence`, `eq_bypass` and the band array are
// the assertions, because those are exactly what the real machine showed as zero.

final class EQLifecycleOwnershipTests: XCTestCase {

    private var fixture: SharedMemoryFixture!
    private var manager: SharedMemoryMappingManager!
    private var deviceUID: String!

    override func setUp() {
        super.setUp()
        fixture = SharedMemoryFixture(name: "eq-ownership-\(UUID().uuidString)")
        manager = SharedMemoryMappingManager(pathForUID: { [path = fixture.path] _ in path })
        manager.deviceUIDProvider = { "eq-ownership-device" }
        deviceUID = "eq-ownership-\(UUID().uuidString)"
        clearDefaults()
    }

    override func tearDown() {
        manager?.stop()
        manager = nil
        fixture?.teardown()
        fixture = nil
        clearDefaults()
        deviceUID = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func seed(bass: Float, mids: Float, treble: Float, enabled: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(bass, forKey: EQDefaultsKey.bass(for: deviceUID))
        defaults.set(mids, forKey: EQDefaultsKey.mids(for: deviceUID))
        defaults.set(treble, forKey: EQDefaultsKey.treble(for: deviceUID))
        defaults.set(enabled, forKey: EQDefaultsKey.isEnabled(for: deviceUID))
    }

    private func clearDefaults() {
        guard let deviceUID else { return }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: EQDefaultsKey.bass(for: deviceUID))
        defaults.removeObject(forKey: EQDefaultsKey.mids(for: deviceUID))
        defaults.removeObject(forKey: EQDefaultsKey.treble(for: deviceUID))
        defaults.removeObject(forKey: EQDefaultsKey.isEnabled(for: deviceUID))
    }

    @discardableResult
    private func publishAndAttach() throws -> FixtureIncarnation {
        let incarnation = try fixture.publish()
        XCTAssertTrue(manager.attachSynchronously(path: fixture.path).didAttach)
        return incarnation
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func bands(of snapshot: RFEQSnapshot) -> [Float] {
        var copy = snapshot
        return withUnsafeBytes(of: &copy.bands) { Array($0.bindMemory(to: Float.self)) }
    }

    /// Read the EQ block through a *second* mapping of the published path — the
    /// way the Host's own process reads it. Deliberately not the writer's view.
    private func readPublishedEQ() throws -> (sequence: UInt32, snapshot: RFEQSnapshot?) {
        let fd = open(fixture.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0, "published mapping must exist")
        defer { close(fd) }

        var info = stat()
        XCTAssertEqual(fstat(fd, &info), 0)
        let size = Int(info.st_size)
        guard size > 0, let raw = mmap(nil, size, PROT_READ, MAP_SHARED, fd, 0), raw != MAP_FAILED else {
            throw XCTSkip("could not map the published file")
        }
        defer { munmap(raw, size) }

        let memory = raw.assumingMemoryBound(to: RFSharedAudio.self)
        var snapshot = RFEQSnapshot()
        let readable = rf_load_eq_snapshot_safe(memory, &snapshot)
        // Offset 152 is pinned by the `static_assert` in RFSharedAudio.h.
        let sequence = UnsafeRawPointer(memory).advanced(by: 152).load(as: UInt32.self)
        return (sequence, readable ? snapshot : nil)
    }

    // MARK: - 1. The writer exists before any mapping does

    func testTheWriterIsCreatedBeforeAnyMappingExists() {
        seed(bass: 6, mids: -3, treble: 2, enabled: true)

        let service = EQService(deviceUID: deviceUID, mapping: manager)

        XCTAssertFalse(manager.isAvailable, "nothing has been published yet")
        XCTAssertEqual(service.controller.bass, 6, accuracy: 0.0001, "persisted values are loaded at construction")
        XCTAssertEqual(service.controller.mids, -3, accuracy: 0.0001)
        XCTAssertEqual(service.controller.treble, 2, accuracy: 0.0001)
        XCTAssertFalse(service.controller.isAppliedToCurrentMapping)
        XCTAssertNil(service.controller.lastAppliedGeneration)
    }

    // MARK: - 2. First publication reaches a writer that already exists

    func testTheWriterAppliesTheFirstPublishedMapping() throws {
        seed(bass: 6, mids: -3, treble: 2, enabled: true)
        let service = EQService(deviceUID: deviceUID, mapping: manager)

        let incarnation = try publishAndAttach()

        XCTAssertTrue(waitUntil { service.controller.isAppliedToCurrentMapping })
        XCTAssertEqual(incarnation.bandGains, EQController.computeBandGains(bass: 6, mids: -3, treble: 2))
        XCTAssertEqual(incarnation.eqSnapshot?.bypass, false)
        XCTAssertGreaterThan(incarnation.eqSequence, 0)
    }

    // MARK: - 3. A late writer still finds the current incarnation

    func testAWriterCreatedAfterThePublicationAppliesImmediately() throws {
        seed(bass: 6, mids: -3, treble: 2, enabled: true)
        let incarnation = try publishAndAttach()
        // A second attach is the `.alreadyCurrent` case: the manager validates
        // the identity and publishes nothing, because nothing changed.
        XCTAssertTrue(manager.attachSynchronously(path: fixture.path).isCurrent)

        let service = EQService(deviceUID: deviceUID, mapping: manager)

        XCTAssertTrue(service.controller.isAppliedToCurrentMapping,
                      "a publication that happened before the writer existed must not be lost")
        XCTAssertEqual(service.controller.lastAppliedGeneration, manager.currentGeneration)
        XCTAssertEqual(incarnation.bandGains, EQController.computeBandGains(bass: 6, mids: -3, treble: 2))
    }

    // MARK: - 4. The Gate 3 scenario, end to end

    /// The real machine's sequence, reproduced without a view:
    ///
    /// `App starts → Mapping published → Popover never opened → EQ snapshot is correct`
    ///
    /// The values are the ones the machine actually had: bass 0.02278646,
    /// mids 12, treble 0, EQ disabled.
    func testGate3ScenarioTheWriterAppliesWithoutAnyViewOrPopover() throws {
        seed(bass: 0.02278646, mids: 12, treble: 0, enabled: false)

        // AppDelegate order: the writer exists first, then the mapping manager
        // starts, then (and only then) a Host may publish.
        let service = EQService(deviceUID: deviceUID, mapping: manager)
        manager.start()

        // No MenuBarView is constructed anywhere in this test: the popover is
        // never opened, which on the real machine was the difference between
        // `eq_sequence = 0` and `eq_sequence = 2`.
        let incarnation = try fixture.publish()
        // What the IPC notification and the 2s fallback do: re-read the identity
        // at the path instead of trusting a notification.
        manager.revalidate()
        XCTAssertTrue(waitUntil { manager.isAvailable }, "the App notices the new mapping")
        XCTAssertTrue(waitUntil { service.controller.isAppliedToCurrentMapping })

        let published = try readPublishedEQ()
        let snapshot = try XCTUnwrap(published.snapshot, "the EQ block must be readable through the SeqLock")

        XCTAssertGreaterThan(published.sequence, 0, "eq_sequence must be non-zero without opening the popover")
        XCTAssertEqual(published.sequence, 2, "one full SeqLock write advances the counter by 2")
        XCTAssertEqual(snapshot.bypass, true, "EQ disabled must be written as bypass")
        XCTAssertEqual(
            bands(of: snapshot),
            EQController.computeBandGains(bass: 0.02278646, mids: 12, treble: 0),
            "the snapshot must match the persisted values, not an all-zero block"
        )
        // The writer's own view of the file agrees with the second reader.
        XCTAssertEqual(incarnation.bandGains, bands(of: snapshot))
        XCTAssertEqual(incarnation.eqSequence, published.sequence)
    }

    // MARK: - 5. Re-attaching the same incarnation writes nothing

    func testRepeatedAttachThroughTheAppWriterDoesNotRewrite() throws {
        seed(bass: 6, mids: -3, treble: 2, enabled: true)
        let service = EQService(deviceUID: deviceUID, mapping: manager)
        let incarnation = try publishAndAttach()
        XCTAssertTrue(waitUntil { service.controller.isAppliedToCurrentMapping })

        let sequenceAfterFirstWrite = incarnation.eqSequence
        let generation = manager.currentGeneration

        for _ in 0..<3 {
            service.controller.attachSharedMemory(for: deviceUID)
            XCTAssertTrue(manager.attachSynchronously(path: fixture.path).isCurrent)
        }
        manager.revalidate()
        _ = waitUntil(timeout: 0.3) { false }

        XCTAssertEqual(manager.currentGeneration, generation, "an unchanged inode is not a new incarnation")
        XCTAssertEqual(incarnation.eqSequence, sequenceAfterFirstWrite, "the same incarnation must not be written twice")
    }

    // MARK: - 6. A new Host incarnation is restored from the newest values

    func testANewHostIncarnationGetsThePersistedValuesAgain() throws {
        seed(bass: 6, mids: -3, treble: 2, enabled: true)
        let service = EQService(deviceUID: deviceUID, mapping: manager)
        let first = try publishAndAttach()
        XCTAssertTrue(waitUntil { service.controller.isAppliedToCurrentMapping })

        service.controller.bass = -9
        XCTAssertEqual(service.controller.flushToSharedMemory(), .written(generation: manager.currentGeneration))
        let sequenceBeforeRestart = first.eqSequence

        // Host-only restart: a new inode, a new session, a new epoch, same path.
        let second = try publishAndAttach()
        XCTAssertNotEqual(second.identity.inode, first.identity.inode)
        XCTAssertTrue(waitUntil { service.controller.lastAppliedGeneration == manager.currentGeneration })

        XCTAssertEqual(second.bandGains, EQController.computeBandGains(bass: -9, mids: -3, treble: 2))
        XCTAssertEqual(first.eqSequence, sequenceBeforeRestart, "the retired incarnation must never be written again")
    }

    // MARK: - 7. Retire then republish

    func testTheWriterWithdrawsItsClaimWhenTheMappingIsRetiredAndReappliesLater() throws {
        seed(bass: 6, mids: -3, treble: 2, enabled: true)
        let service = EQService(deviceUID: deviceUID, mapping: manager)
        _ = try publishAndAttach()
        XCTAssertTrue(waitUntil { service.controller.isAppliedToCurrentMapping })

        fixture.removePublishedFile()
        manager.revalidate()

        XCTAssertTrue(waitUntil { !service.controller.isAppliedToCurrentMapping })
        XCTAssertNil(service.controller.lastAppliedGeneration)
        XCTAssertFalse(manager.isAvailable)
        XCTAssertEqual(service.controller.bass, 6, accuracy: 0.0001, "the values stay available for the next Host")

        let republished = try publishAndAttach()
        XCTAssertTrue(waitUntil { service.controller.isAppliedToCurrentMapping })
        XCTAssertEqual(republished.bandGains, EQController.computeBandGains(bass: 6, mids: -3, treble: 2))
    }

    // MARK: - 8. A failed write never claims success

    func testWithoutAMappingTheWriterNeverClaimsToBeApplied() {
        seed(bass: 6, mids: -3, treble: 2, enabled: true)
        let service = EQService(deviceUID: deviceUID, mapping: manager)

        XCTAssertEqual(service.controller.flushToSharedMemory(), .unavailable)
        XCTAssertFalse(service.controller.isAppliedToCurrentMapping)
        XCTAssertNil(service.controller.lastAppliedGeneration)
    }

    // MARK: - 9. One writer per process

    func testTheProcessHasExactlyOneAppOwnedWriter() {
        // Read-only: `EQService.shared` loads the persisted values and asks the
        // real manager for the current incarnation. The manager has no mapping in
        // the test process, so nothing is written anywhere.
        XCTAssertTrue(EQService.shared.controller === EQService.shared.controller)
        XCTAssertTrue(EQService.shared.controller === EQService.shared.controller)
    }
}

// MARK: - Source ownership boundary
//
// The runtime tests above prove the *behaviour*. They cannot prove that no other
// file quietly builds a second writer, because the popover is the one place a
// test process never reaches. These assertions read the sources, in the same
// spirit as `DriverInstallBoundaryTests`: a new construction site is a product
// decision, and it fails here until someone makes it deliberately.

final class EQOwnershipBoundaryTests: XCTestCase {

    private struct SourceFile {
        let relativePath: String
        /// Comment-only lines blanked, so a doc comment naming a symbol is not
        /// mistaken for a call site. Line numbers survive.
        let code: [String]

        func occurrences(of needle: String) -> [String] {
            code.filter { $0.contains(needle) }
        }

        func contains(_ needle: String) -> Bool {
            !occurrences(of: needle).isEmpty
        }
    }

    private static var cachedSources: [SourceFile]?

    private var sources: [SourceFile] {
        get throws {
            if let cached = Self.cachedSources { return cached }
            let loaded = try Self.loadSources()
            Self.cachedSources = loaded
            return loaded
        }
    }

    private static func loadSources() throws -> [SourceFile] {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SoundBridgeAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // SoundBridgeApp
        let sourcesRoot = appRoot.appendingPathComponent("Sources", isDirectory: true)

        guard let walker = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: nil
        ) else {
            throw XCTSkip("could not enumerate \(sourcesRoot.path)")
        }

        var files: [SourceFile] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = text
                .components(separatedBy: .newlines)
                .map { line -> String in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return trimmed.hasPrefix("//") ? "" : line
                }
            let relative = url.path.replacingOccurrences(of: appRoot.path + "/", with: "")
            files.append(SourceFile(relativePath: relative, code: code))
        }

        XCTAssertFalse(files.isEmpty, "source scan found no files; the path derivation is wrong")
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private func file(_ suffix: String) throws -> SourceFile {
        try XCTUnwrap(sources.first { $0.relativePath.hasSuffix(suffix) }, "missing \(suffix)")
    }

    private func filesContaining(_ needle: String) throws -> [(path: String, lines: [String])] {
        try sources.compactMap { file in
            let hits = file.occurrences(of: needle)
            return hits.isEmpty ? nil : (file.relativePath, hits)
        }
    }

    // MARK: 1. One construction site

    func testOnlyTheServiceConstructsAnEQController() throws {
        let hits = try filesContaining("EQController(")

        XCTAssertEqual(
            hits.map(\.path),
            ["Sources/Services/EQService.swift"],
            "a second construction site is a second writer, which is the Gate 3 defect"
        )
        XCTAssertEqual(hits.first?.lines.count, 1)
    }

    func testTheServiceHoldsTheOnlyInstance() throws {
        let service = try file("Services/EQService.swift")

        XCTAssertTrue(service.contains("static let shared = EQService()"))
        XCTAssertTrue(service.contains("let controller: EQController"))
    }

    // MARK: 2. The view observes, it does not create

    func testMenuBarViewObservesTheAppOwnedController() throws {
        let view = try file("Views/MenuBarView.swift")

        XCTAssertTrue(
            view.contains("@ObservedObject private var eqController: EQController"),
            "the view must receive the App's writer"
        )
        XCTAssertFalse(
            view.contains("@StateObject private var eqController"),
            "@StateObject would create a writer when the popover first renders"
        )
        XCTAssertFalse(view.contains("EQController("), "the view must never construct a writer")
    }

    // MARK: 3. The App creates the writer before the mapping can publish

    func testTheAppDelegateCreatesTheWriterBeforeStartingTheMapping() throws {
        let app = try file("App/SoundBridgeApp.swift")
        let joined = app.code.joined(separator: "\n")

        let writer = try XCTUnwrap(joined.range(of: "private let eqService = EQService.shared"),
                                   "the App must own the writer")
        let mappingStart = try XCTUnwrap(joined.range(of: "SharedMemoryMappingManager.shared.start()"),
                                         "the mapping manager must still be started at launch")

        XCTAssertLessThan(
            joined.distance(from: joined.startIndex, to: writer.lowerBound),
            joined.distance(from: joined.startIndex, to: mappingStart.lowerBound),
            "the writer must exist before the first publication can arrive"
        )
        XCTAssertTrue(
            joined.contains("MenuBarView(eqController: eqService.controller)"),
            "the popover must be handed the App's writer"
        )
    }

    // MARK: 4. A Host exit never terminates the App

    func testTheAppNoLongerTerminatesItselfWhenTheHostExits() throws {
        let app = try file("App/SoundBridgeApp.swift")

        XCTAssertFalse(app.contains("NSApp.terminate"), "a Host event must not quit the App")
        XCTAssertFalse(app.contains("hostProcess"), "the supervisor owns the process now")
        XCTAssertTrue(app.contains("hostSupervisor.shutdown(intent: .appTermination"))
        XCTAssertTrue(app.contains("hostSupervisor.start()"))
    }

    // MARK: 5. The restart entry point exists and is internal-only

    func testHostOnlyRestartIsExposedWithoutAMenuItem() throws {
        let app = try file("App/SoundBridgeApp.swift")
        XCTAssertTrue(app.contains("func restartHost()"))
        XCTAssertTrue(app.contains("hostSupervisor.restart()"))

        let view = try file("Views/MenuBarView.swift")
        XCTAssertFalse(view.contains("restartHost"), "no user-facing restart button in this batch")
    }

    // MARK: 6. The supervisor stays inside its boundaries

    func testTheSupervisorNeverTouchesTheDriverOrCoreAudio() throws {
        let supervisor = try file("Services/HostSupervisor.swift")

        XCTAssertFalse(supervisor.contains("coreaudiod"))
        XCTAssertFalse(supervisor.contains("killall"))
        XCTAssertFalse(supervisor.contains("Plug-Ins/HAL"))
        // One kill: the SIGKILL ceiling after SIGTERM. Nothing else signals.
        XCTAssertEqual(supervisor.occurrences(of: "kill(").count, 1)
        XCTAssertTrue(supervisor.contains("process.terminate()"), "SIGTERM through Process, not by PID")
    }

    func testTheSupervisorStopsForEveryFinalIntent() throws {
        let supervisor = try file("Services/HostSupervisor.swift")

        XCTAssertTrue(supervisor.contains("case .appTermination, .uninstall:"))
        XCTAssertTrue(supervisor.contains("case .restart:"))
        XCTAssertTrue(
            supervisor.contains("maxConsecutiveFailures"),
            "unbounded retries would be a restart storm"
        )
        XCTAssertTrue(supervisor.contains("asyncAfter(deadline:"), "backoff, not a tight loop")
    }
}
