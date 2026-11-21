import Foundation

/// Owns the App's single EQ writer for the whole process lifetime.
///
/// The Gate 3 defect this type exists to remove: `EQController` used to be a
/// `@StateObject` inside `MenuBarView`, and `MenuBarView` is only instantiated
/// when the popover is first shown. A user who launched the App and played audio
/// without opening the menu bar therefore had *no writer* for the EQ block — the
/// Host's new mapping stayed at `eq_sequence = 0` with an all-zero snapshot while
/// UserDefaults held the real values. Opening the popover created the controller,
/// and only then did the values reach shared memory.
///
/// `SharedMemoryMappingManager` was already App-level after P2 Batch 3; this is
/// the missing half. Creating the controller here — before `mapping.start()` and
/// before any View exists — means:
///
/// 1. the controller subscribes to `mappingPublished` before the first
///    publication, so it cannot miss it;
/// 2. if a mapping already exists at construction, `EQController` asks the
///    manager for the current incarnation (`.alreadyCurrent` publishes nothing);
/// 3. `MenuBarView` receives this instance instead of building its own, so the
///    popover being closed (or never opened) changes nothing about the writer.
///
/// Deliberately thin. Everything about EQ values, band mapping, persistence and
/// lease-safe writes stays in `EQController`; this only decides *when it exists*.
final class EQService {

    /// The one writer for this process. `AppDelegate` touches this during
    /// `applicationDidFinishLaunching`, which is the first access in production —
    /// so the controller is created there, not on the first time the menu bar is
    /// rendered. Tests build their own instance against a fixture mapping.
    static let shared = EQService()

    /// The live controller. `MenuBarView` observes this object; it never creates
    /// one, and `EQController` has no other production construction site.
    let controller: EQController

    /// Production: the shared manager and the `"default"` device key the App has
    /// always persisted EQ under (`eq_default_*` in UserDefaults).
    init(
        deviceUID: String = "default",
        mapping: SharedMemoryMappingManager = .shared
    ) {
        controller = EQController(deviceUID: deviceUID, mapping: mapping)
    }
}
