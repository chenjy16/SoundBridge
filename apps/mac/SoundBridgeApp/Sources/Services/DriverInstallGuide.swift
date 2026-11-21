import Foundation

/// Where the official driver installer package is, and what opening it means.
///
/// The app does not install the driver (`DriverInstaller` explains why), so
/// onboarding has to point at the package that does. Two questions are decided
/// here rather than in the view, so both can be tested without a package, a
/// mount or a running app: which `.pkg` to open when one is beside the app, and
/// what to offer when there is not one.
///
/// The package is the release's `SoundBridge-<version>.pkg`. Opening it starts
/// Apple's installer, which asks for administrator rights once and runs
/// `tools/sb_install_transaction.sh` — the staged replace with a backup,
/// a verification pass and a rollback. Nothing on this path copies files.
enum DriverInstallGuide {

    /// What the onboarding page should offer.
    enum Action: Equatable {
        /// A `SoundBridge-*.pkg` sits beside the app: hand it to LaunchServices.
        case openPackage(URL)
        /// Nothing local, but the build names a release page: send the user there.
        case openReleasePage(URL)
        /// Nothing local and no usable URL: name the file to look for, no action.
        case namePackage(String)
    }

    /// The file name a release publishes, e.g. `SoundBridge-1.2.0.pkg`.
    static func packageFileName(appVersion: String) -> String {
        "SoundBridge-\(appVersion).pkg"
    }

    /// The directory a package would be in: the one holding the app.
    ///
    /// That covers the two downloads this product has. A `.dmg` mounts at
    /// `/Volumes/...` with the app inside it, so a package shipped in the same
    /// image is found; a copy dragged to `/Applications` finds a package left
    /// in that folder. Nothing else is searched on purpose: guessing at a
    /// user's Downloads folder would be a promise this page cannot keep.
    static func searchDirectories(appBundleURL: URL) -> [URL] {
        [appBundleURL.deletingLastPathComponent()]
    }

    /// The package to open, if one of `directories` holds a `SoundBridge-*.pkg`.
    ///
    /// `preferring` picks the file whose name carries this build's version,
    /// because an upgrade usually leaves the previous download next to the new
    /// one. Without a match the first name in sorted order wins, so the choice is
    /// stable between launches instead of depending on directory order.
    static func locatePackage(in directories: [URL],
                              preferring version: String? = nil,
                              fileManager: FileManager = .default) -> URL? {
        var candidates: [URL] = []
        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { continue }
            candidates.append(contentsOf: entries.filter { url in
                url.pathExtension == "pkg" && url.lastPathComponent.hasPrefix("SoundBridge-")
            })
        }

        let sorted = candidates.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let version,
           let exact = sorted.first(where: {
               $0.lastPathComponent == packageFileName(appVersion: version)
           }) {
            return exact
        }
        return sorted.first
    }

    /// The action for this build, in this location.
    static func action(appBundleURL: URL = Bundle.main.bundleURL,
                       appVersion: String?,
                       releasePageURL: URL?,
                       fileManager: FileManager = .default) -> Action {
        if let package = locatePackage(
            in: searchDirectories(appBundleURL: appBundleURL),
            preferring: appVersion,
            fileManager: fileManager
        ) {
            return .openPackage(package)
        }
        if let releasePageURL {
            return .openReleasePage(releasePageURL)
        }
        return .namePackage(packageFileName(appVersion: appVersion ?? "<version>"))
    }
}
