import XCTest
@testable import SoundBridgeApp

// MARK: - Driver install boundary (Phase 2.1.5-D)
//
// The product decision is that this build keeps the *capability* to install and
// upgrade the HAL driver while shipping no entry point that does it on its own.
// That is a claim about the source, not about a runtime mode, so it is asserted
// against the source: every place that can reach a privileged copy is enumerated
// and anything new fails the test.
//
// Evidence level: L1/L2. These tests read files and check policy constants. They
// deliberately do not launch the App, and nothing here installs anything.

final class DriverInstallBoundaryTests: XCTestCase {

    private struct SourceFile {
        let relativePath: String
        /// Source lines with comment-only lines blanked out, so a doc comment that
        /// names a function is not mistaken for a call site. Line numbers survive.
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

    /// `Sources/` next to this test bundle's package root, derived from the test
    /// file's own path so the test works from any working directory.
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

    /// Files whose non-comment source contains `needle`, with the matching lines.
    private func filesContaining(_ needle: String) throws -> [(path: String, lines: [String])] {
        try sources.compactMap { file in
            let hits = file.occurrences(of: needle)
            return hits.isEmpty ? nil : (file.relativePath, hits)
        }
    }

    // MARK: - 1. Who may call the installer

    func testOnlyTwoCallSitesReachTheInstaller() throws {
        let callSites = try filesContaining(".installDriver(intent:")

        XCTAssertEqual(
            callSites.map(\.path).sorted(),
            [
                "Sources/App/SoundBridgeApp.swift",
                "Sources/Onboarding/OnboardingView.swift",
            ],
            "a new install call site is a product decision, not a refactor"
        )

        for site in callSites {
            XCTAssertEqual(site.lines.count, 1, "\(site.path) should hold exactly one install call")
        }
    }

    func testFirstInstallIsTheOnlyIntentConstructedInTheUi() throws {
        let onboarding = try XCTUnwrap(sources.first { $0.relativePath.hasSuffix("OnboardingView.swift") })

        XCTAssertTrue(onboarding.contains("installDriver(intent: .firstInstall)"),
                      "onboarding performs a first install and nothing else")
        XCTAssertFalse(onboarding.contains(".explicitUpgrade"),
                       "an upgrade intent in onboarding would be an unrequested driver replacement")
    }

    func testOnboardingInstallIsReachableOnlyFromAUserAction() throws {
        let onboarding = try XCTUnwrap(sources.first { $0.relativePath.hasSuffix("OnboardingView.swift") })

        // One button wires the install; a timer, notification or launch hook
        // inside onboarding would show up as a second reference.
        let references = onboarding.code.filter { line in
            line.contains("installDriver")
                && !line.contains("func installDriver()")
                && !line.contains(".installDriver(intent:")
        }
        XCTAssertEqual(references.count, 1,
                       "the only reference to installDriver() outside its definition must be the button: \(references)")
        XCTAssertTrue(references[0].contains("Button(action: installDriver)"),
                      "unexpected install entry point: \(references[0])")
    }

    // MARK: - 2. The upgrade prompt is not wired

    func testUpgradePromptHasNoCallSite() throws {
        let hits = try filesContaining("showDriverUpdatePrompt")

        XCTAssertEqual(hits.count, 1, "showDriverUpdatePrompt must only exist where it is defined")
        XCTAssertEqual(hits.first?.path, "Sources/App/SoundBridgeApp.swift")
        XCTAssertEqual(hits.first?.lines.count, 1,
                       "a call site means the disabled prompt became reachable: \(hits.first?.lines ?? [])")
    }

    func testPerformDriverUpdateIsUnreachable() throws {
        let hits = try filesContaining("performDriverUpdate")

        XCTAssertEqual(hits.map(\.path), ["Sources/App/SoundBridgeApp.swift"])
        // Definition plus the closure inside the (uncallable) prompt window.
        XCTAssertEqual(hits.first?.lines.count, 2,
                       "unexpected caller of performDriverUpdate: \(hits.first?.lines ?? [])")
        for line in hits.first?.lines ?? [] {
            XCTAssertTrue(
                line.contains("func performDriverUpdate()") || line.contains("self?.performDriverUpdate()"),
                "unexpected reference: \(line)"
            )
        }
    }

    // MARK: - 3. Privileged operations are enumerated

    func testExactlyTwoPrivilegedScriptsExist() throws {
        let hits = try filesContaining("with administrator privileges")

        XCTAssertEqual(
            hits.map(\.path).sorted(),
            [
                "Sources/Services/DriverInstaller.swift",
                "Sources/Views/MenuBarView.swift",
            ],
            "a new privileged script needs its own review, not a passing test"
        )

        for site in hits {
            XCTAssertEqual(site.lines.count, 1, "\(site.path) should hold a single admin prompt")
        }
    }

    func testOnlyTheInstallerAndTheUninstallerRestartCoreAudio() throws {
        let hits = try filesContaining("killall coreaudiod")

        XCTAssertEqual(
            hits.map(\.path).sorted(),
            [
                "Sources/Services/DriverInstaller.swift",
                "Sources/Views/MenuBarView.swift",
            ],
            "coreaudiod may only be restarted from an explicit driver install or removal"
        )
    }

    func testPrivilegedCopyIsPrivateAndCalledOnce() throws {
        let installer = try XCTUnwrap(sources.first { $0.relativePath.hasSuffix("DriverInstaller.swift") })

        let references = installer.occurrences(of: "installDriverWithPrivileges")
        XCTAssertEqual(references.count, 2, "expected the declaration and exactly one call: \(references)")
        XCTAssertTrue(
            references.contains { $0.contains("private func installDriverWithPrivileges") },
            "the privileged step must stay private to the installer"
        )
        XCTAssertEqual(
            installer.occurrences(of: "cp -R").count, 1,
            "a second copy step would be a second unguarded way to replace the driver"
        )
    }

    // MARK: - 4. Policy is still the source of truth

    func testShippingPolicyRemainsReportOnly() {
        XCTAssertFalse(DriverUpgradePolicy.allowsUserFacingPrompt,
                       "an upgrade prompt is an entry point; this build ships none")
        XCTAssertFalse(DriverUpgradePolicy.allowsAutomaticInstall,
                       "an install needs an explicit user action")
        XCTAssertTrue(DriverUpgradePolicy.allowsCompatibilityNotice,
                      "an unusable driver must still be explained, without an install action")
    }

    func testInstallerStillRefusesIntentsThatDoNotMatch() {
        // The gate the two call sites depend on. If this loosens, the boundary
        // above stops meaning anything.
        XCTAssertFalse(DriverInstallIntent.firstInstall.permits(.outdated(installed: "1.1.3", expected: "1.2.0")))
        XCTAssertFalse(DriverInstallIntent.firstInstall.permits(.compatible(version: "1.2.0")))
        XCTAssertFalse(
            DriverInstallIntent.explicitUpgrade(from: "1.1.3", to: "1.2.0")
                .permits(.newer(installed: "1.3.0", expected: "1.2.0"))
        )
    }

    func testFirstInstallRefusesANewerDriver() {
        // Phase 3.2C. `.newer` means the driver on disk is ahead of this build.
        // A first install must not overwrite it, so the last line of defence has
        // to refuse it even if some future surface asks for one.
        XCTAssertFalse(
            DriverInstallIntent.firstInstall.permits(.newer(installed: "1.1.2", expected: "1.1.1"))
        )
        XCTAssertNil(
            DriverVersionStatus.newer(installed: "1.1.2", expected: "1.1.1").installIntent,
            "nothing is installed for a newer driver"
        )
    }

    // MARK: - 5. Onboarding offers no action for a newer driver (Phase 3.2C)

    func testOnboardingOffersAnInstallOnlyWhenNothingIsInstalled() throws {
        let onboarding = try XCTUnwrap(sources.first { $0.relativePath.hasSuffix("OnboardingView.swift") })

        // The button and the action are both gated on `isFirstInstall`, which is
        // exactly `status == .notInstalled`. `.newer` must reach neither: a
        // button there would replace a driver that is ahead of this build.
        XCTAssertTrue(
            onboarding.contains("private var isFirstInstall: Bool {"),
            "the install decision moved; re-check what gates the button"
        )
        XCTAssertTrue(onboarding.contains("status == .notInstalled"))
        XCTAssertTrue(
            onboarding.contains("} else if isFirstInstall {"),
            "the install button must sit behind the first-install check"
        )
        XCTAssertTrue(
            onboarding.contains("guard isFirstInstall else {"),
            "the install action must refuse every state other than first install"
        )
        XCTAssertTrue(
            onboarding.contains("Text(headline)"),
            "the page must use the notice's own title rather than a hardcoded one"
        )
        XCTAssertTrue(
            onboarding.contains("if let notice { return notice.title }"),
            "the newer-driver headline comes from the notice"
        )
    }
}
