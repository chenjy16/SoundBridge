import XCTest
@testable import SoundBridgeApp

// MARK: - Compatibility notice
//
// §2.4: forbidding the upgrade entry point is not permission to fail silently.
// A driver that speaks another protocol leaves the user with no audio; the app
// has to say what is wrong, with versions, and where to get a matching package —
// and it must not guess that location. These tests cover the text, the status
// matrix, and the fact that the download link comes from the app's own
// configured update feed.

final class DriverCompatibilityNoticeTests: XCTestCase {

    private let appVersion = "1.2.0"

    /// One ABI generation behind whatever this build speaks. Written as a delta
    /// rather than a literal so a protocol bump cannot leave a stale sample here.
    private let incompatibleProtocol = DriverVersionGate.expectedProtocolVersion - 0x100

    // MARK: - Which statuses get a notice

    func testNoticeIsProducedForEveryUnusableStatus() {
        let statuses: [DriverVersionStatus] = [
            .outdated(installed: "1.1.3", expected: "1.2.0"),
            .protocolIncompatible(
                installedVersion: "1.2.0",
                installedProtocol: incompatibleProtocol,
                expectedProtocol: DriverVersionGate.expectedProtocolVersion
            ),
            .metadataUnreadable(reason: "Info.plist is missing"),
            .expectedVersionUnavailable
        ]

        for status in statuses {
            XCTAssertTrue(DriverCompatibilityNotice.shouldPresent(for: status), "no notice for \(status)")
            XCTAssertNotNil(
                DriverCompatibilityNotice.make(for: status, appVersion: appVersion, releasePageURL: nil),
                "make returned nil for \(status)"
            )
        }
    }

    func testNoticeIsNotProducedForHealthyOrAbsentDrivers() {
        // `.notInstalled` is onboarding's job and `.compatible` is healthy. An
        // alert for either would be the noise §2.4 warns about in the other
        // direction. `.newer` is covered separately below: it is described, but
        // not raised at launch.
        let statuses: [DriverVersionStatus] = [
            .notInstalled,
            .compatible(version: "1.2.0")
        ]

        for status in statuses {
            XCTAssertFalse(DriverCompatibilityNotice.shouldPresent(for: status), "unexpected notice for \(status)")
            XCTAssertNil(DriverCompatibilityNotice.make(for: status, appVersion: appVersion, releasePageURL: nil))
        }
    }

    // MARK: - The driver is newer than the app (Phase 3.2C)

    func testNewerDriverIsDescribedButNotRaisedAtLaunch() throws {
        // The state that used to produce nothing at all, and so fell through to
        // the first-install copy. Nothing here may be raised as an unsolicited
        // launch alert — but it must be describable, because the screen that
        // reports the driver is where the user meets this.
        let status = DriverVersionStatus.newer(installed: "1.1.2", expected: "1.1.1")

        XCTAssertFalse(
            DriverCompatibilityNotice.shouldPresent(for: status),
            "a newer driver is not a problem to interrupt the user with at launch"
        )

        let notice = try XCTUnwrap(
            DriverCompatibilityNotice.make(for: status, appVersion: appVersion, releasePageURL: nil)
        )
        XCTAssertEqual(notice.title, "App and Driver Versions Do Not Match")
    }

    func testNewerDriverNoticeNamesAllThreeVersions() throws {
        let status = DriverVersionStatus.newer(installed: "1.1.2", expected: "1.1.1")
        let notice = try XCTUnwrap(
            DriverCompatibilityNotice.make(for: status, appVersion: appVersion, releasePageURL: nil)
        )

        let body = notice.message
        XCTAssertTrue(body.contains("1.1.2"), "installed driver version missing:\n\(body)")
        XCTAssertTrue(body.contains("1.1.1"), "supported driver version missing:\n\(body)")
        XCTAssertTrue(body.contains("SoundBridge \(appVersion)"), "app version missing:\n\(body)")
        XCTAssertTrue(notice.lines.contains("Installed driver: 1.1.2"))
        XCTAssertTrue(notice.lines.contains("This version of SoundBridge supports: 1.1.1"))
        XCTAssertTrue(body.contains("will not replace the system driver in the background"))
    }

    func testNewerDriverNoticeDoesNotInviteADowngrade() throws {
        // The recovery for this state is an app update. Telling the user to fetch
        // and run a package is the instruction that would replace a newer driver
        // with this build's older copy, so that sentence must not be there.
        let status = DriverVersionStatus.newer(installed: "1.1.2", expected: "1.1.1")
        let url = try XCTUnwrap(URL(string: "https://github.com/chenjy16/SoundBridge/releases"))
        let notice = try XCTUnwrap(
            DriverCompatibilityNotice.make(for: status, appVersion: appVersion, releasePageURL: url)
        )

        let body = notice.message
        XCTAssertFalse(body.contains("download the full package"), "the notice invites an install:\n\(body)")
        XCTAssertFalse(body.contains("cannot use the audio driver"), "wrong diagnosis:\n\(body)")
        XCTAssertTrue(body.contains("update SoundBridge"), "the recovery is an app update:\n\(body)")
        XCTAssertTrue(
            body.contains("Do not reinstall or downgrade the installed driver"),
            "the notice does not warn against touching the driver:\n\(body)"
        )
        XCTAssertTrue(
            body.contains("https://github.com/chenjy16/SoundBridge/releases"),
            "where to get a newer app is missing:\n\(body)"
        )
    }

    func testNewerDriverNoticeOmitsTheLinkRatherThanInventingOne() throws {
        let status = DriverVersionStatus.newer(installed: "1.1.2", expected: "1.1.1")
        let notice = try XCTUnwrap(
            DriverCompatibilityNotice.make(for: status, appVersion: appVersion, releasePageURL: nil)
        )

        XCTAssertFalse(notice.message.contains("https://"), "no URL should be fabricated:\n\(notice.message)")
        XCTAssertTrue(notice.message.contains("releases page"))
    }

    // MARK: - Content

    func testProtocolMismatchNoticeCarriesBothProtocolVersions() {
        let installedProtocol = incompatibleProtocol
        let expectedProtocol = DriverVersionGate.expectedProtocolVersion
        let status = DriverVersionStatus.protocolIncompatible(
            installedVersion: "1.1.0",
            installedProtocol: installedProtocol,
            expectedProtocol: expectedProtocol
        )
        let notice = try? XCTUnwrap(
            DriverCompatibilityNotice.make(for: status, appVersion: appVersion, releasePageURL: nil)
        )

        let body = notice?.message ?? ""
        XCTAssertTrue(body.contains("SoundBridge 1.2.0"), "app version missing:\n\(body)")
        XCTAssertTrue(body.contains("1.1.0"), "installed driver version missing:\n\(body)")
        XCTAssertTrue(
            body.contains(DriverVersionGate.hex(installedProtocol)),
            "installed protocol missing:\n\(body)"
        )
        XCTAssertTrue(
            body.contains(DriverVersionGate.hex(expectedProtocol)),
            "expected protocol missing:\n\(body)"
        )
        XCTAssertTrue(
            body.contains("will not replace the system driver in the background"),
            "the no-background-replacement promise is missing:\n\(body)"
        )
    }

    func testOutdatedNoticeNamesInstalledAndExpectedVersions() throws {
        let status = DriverVersionStatus.outdated(installed: "1.1.3", expected: "1.2.0")
        let notice = try XCTUnwrap(
            DriverCompatibilityNotice.make(for: status, appVersion: appVersion, releasePageURL: nil)
        )

        XCTAssertTrue(notice.lines.contains("Installed driver: 1.1.3"))
        XCTAssertTrue(notice.lines.contains("This version needs: 1.2.0"))
        XCTAssertEqual(notice.title, "Audio driver is not compatible with this version")
    }

    func testNoticePointsAtTheReleasePageWhenConfigured() throws {
        let url = try XCTUnwrap(URL(string: "https://github.com/chenjy16/SoundBridge/releases"))
        let status = DriverVersionStatus.outdated(installed: "1.1.3", expected: "1.2.0")
        let notice = try XCTUnwrap(
            DriverCompatibilityNotice.make(for: status, appVersion: appVersion, releasePageURL: url)
        )

        XCTAssertTrue(
            notice.message.contains("https://github.com/chenjy16/SoundBridge/releases"),
            "download location missing:\n\(notice.message)"
        )
        XCTAssertTrue(
            notice.message.contains("download the full package"),
            "the notice must say what to fetch, not just where:\n\(notice.message)"
        )
    }

    func testNoticeOmitsTheLinkRatherThanInventingOne() throws {
        let status = DriverVersionStatus.metadataUnreadable(reason: "Info.plist is missing")
        let notice = try XCTUnwrap(
            DriverCompatibilityNotice.make(for: status, appVersion: appVersion, releasePageURL: nil)
        )

        XCTAssertFalse(notice.message.contains("https://"), "no URL should be fabricated:\n\(notice.message)")
        XCTAssertTrue(notice.message.contains("releases page"))
    }

    // MARK: - Link derivation from configuration

    func testReleasePageIsDerivedFromTheConfiguredFeedURL() throws {
        let feed = try XCTUnwrap(
            URL(string: "https://github.com/chenjy16/SoundBridge/releases/latest/download/appcast.xml")
        )
        XCTAssertEqual(
            DriverCompatibilityNotice.releasePageURL(feedURL: feed)?.absoluteString,
            "https://github.com/chenjy16/SoundBridge/releases"
        )
    }

    func testReleasePageIsDerivedFromTheRealInfoPlist() throws {
        // Reads the bundle the app actually ships rather than a literal in the
        // test, so a repository rename has one place to change and this test
        // fails loudly if the plist and the notice stop agreeing.
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SoundBridgeAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // SoundBridgeApp
            .appendingPathComponent("Info.plist")

        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        let rawFeed = try XCTUnwrap(plist["SUFeedURL"] as? String, "SUFeedURL is not configured")
        let feed = try XCTUnwrap(URL(string: rawFeed))

        let releasePage = try XCTUnwrap(
            DriverCompatibilityNotice.releasePageURL(feedURL: feed),
            "SUFeedURL \(rawFeed) does not describe a GitHub repository"
        )
        XCTAssertEqual(releasePage.absoluteString, "https://github.com/chenjy16/SoundBridge/releases")
    }

    func testNonGitHubFeedProducesNoLink() {
        // A wrong link is worse than none: there is no safe guess to make about
        // where this fork's releases live.
        XCTAssertNil(DriverCompatibilityNotice.releasePageURL(feedURL: URL(string: "https://example.com/appcast.xml")))
        XCTAssertNil(DriverCompatibilityNotice.releasePageURL(feedURL: URL(string: "https://github.com/onlyowner")))
        XCTAssertNil(DriverCompatibilityNotice.releasePageURL(feedURL: URL(string: "appcast.xml")))
        XCTAssertNil(DriverCompatibilityNotice.releasePageURL(feedURL: nil))
    }

    func testReleasePageAcceptsTheWWWHost() throws {
        let feed = try XCTUnwrap(URL(string: "https://www.github.com/owner/repo/releases/latest/download/appcast.xml"))
        XCTAssertEqual(
            DriverCompatibilityNotice.releasePageURL(feedURL: feed)?.absoluteString,
            "https://github.com/owner/repo/releases"
        )
    }
}
