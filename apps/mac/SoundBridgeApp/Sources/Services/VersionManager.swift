import Foundation

/// Manages version reading and comparison across SoundBridge components
struct VersionManager {

	// MARK: - App Version

	/// Get current app version from bundle
	static func appVersion() -> String? {
		return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
	}

	/// Get current app build number
	static func appBuildNumber() -> String? {
		return Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
	}

	// MARK: - App Updates

	/// Whether Sparkle has a usable update feed.
	///
	/// Sparkle needs both `SUFeedURL` and `SUPublicEDKey` in Info.plist. When
	/// either is empty it fails on every launch with "Unable to check for
	/// updates", so the updater must not be started in that case.
	static var isUpdaterConfigured: Bool {
		let info = Bundle.main.infoDictionary
		let feed = (info?["SUFeedURL"] as? String)?
			.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		let key = (info?["SUPublicEDKey"] as? String)?
			.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return !feed.isEmpty && !key.isEmpty
	}

	// MARK: - Driver Versions

	/// Get installed driver version from /Library/Audio/Plug-Ins/HAL/
	static func installedDriverVersion() -> String? {
		let driverPath = "/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver/Contents/Info.plist"

		guard FileManager.default.fileExists(atPath: driverPath),
			  let plistData = FileManager.default.contents(atPath: driverPath),
			  let plist = try? PropertyListSerialization.propertyList(
				from: plistData,
				options: [],
				format: nil
			  ) as? [String: Any],
			  let version = plist["CFBundleShortVersionString"] as? String else {
			return nil
		}

		return version
	}

	/// Get bundled driver version (from app resources)
	static func bundledDriverVersion() -> String? {
		guard let driverPath = findBundledDriver() else {
			return nil
		}

		let plistPath = "\(driverPath)/Contents/Info.plist"

		guard FileManager.default.fileExists(atPath: plistPath),
			  let plistData = FileManager.default.contents(atPath: plistPath),
			  let plist = try? PropertyListSerialization.propertyList(
				from: plistData,
				options: [],
				format: nil
			  ) as? [String: Any],
			  let version = plist["CFBundleShortVersionString"] as? String else {
			return nil
		}

		return version
	}

	// MARK: - Driver Status

	/// Check if driver is installed at system level
	static func isDriverInstalled() -> Bool {
		let driverPath = "/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver"
		return FileManager.default.fileExists(atPath: driverPath)
	}

	// MARK: - Version Comparison

	/// Compare two semantic versions
	/// - Returns: true if v1 < v2, false otherwise
	static func isVersionOlder(_ v1: String, than v2: String) -> Bool {
		return DriverVersionGate.compare(v1, v2) < 0
	}

	/// Compare two semantic versions for equality.
	/// Comparison is numeric and pads missing components, so "1.2" equals "1.2.0".
	static func areVersionsEqual(_ v1: String, _ v2: String) -> Bool {
		return DriverVersionGate.compare(v1, v2) == 0
	}

	// MARK: - Bundle Discovery

	/// Find bundled driver in app resources
	private static func findBundledDriver() -> String? {
		// Search in main bundle resources
		if let bundlePath = Bundle.main.resourcePath {
			let driverPath = "\(bundlePath)/SoundBridgeDriver.driver"
			if FileManager.default.fileExists(atPath: driverPath) {
				return driverPath
			}
		}

		// Search using Bundle API
		if let resourcePath = Bundle.main.path(forResource: "SoundBridgeDriver", ofType: "driver") {
			return resourcePath
		}

		// Development: Check relative path from project root
		let fm = FileManager.default
		if let currentPath = Bundle.main.executablePath {
			let projectRoot = (currentPath as NSString).deletingLastPathComponent
				.appending("/../../../../../packages/driver/build/SoundBridgeDriver.driver")

			let normalizedPath = (projectRoot as NSString).standardizingPath
			if fm.fileExists(atPath: normalizedPath) {
				return normalizedPath
			}
		}

		return nil
	}

	// MARK: - Formatted Display

	/// Get formatted version string for display (e.g., "v1.0.15")
	static func formattedAppVersion() -> String {
		guard let version = appVersion() else {
			return "Unknown"
		}
		return "v\(version)"
	}

	/// Get detailed version string including build number
	static func detailedAppVersion() -> String {
		guard let version = appVersion() else {
			return "Unknown"
		}

		if let build = appBuildNumber(), build != "1" {
			return "v\(version) (build \(build))"
		}

		return "v\(version)"
	}
}
