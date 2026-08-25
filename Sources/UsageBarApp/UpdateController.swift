import AppKit
import Combine
import Sparkle

/// In-app updates.
///
/// Sparkle does the three things that are unpleasant to write and easy to get
/// wrong: it replaces a running app with a helper that survives the swap, it
/// refuses a download whose EdDSA signature was not made with our private key,
/// and it refuses one whose Developer ID team is not the team that signed the
/// app now running. Together those mean a hijacked feed or a hijacked release
/// asset still cannot install anything.
///
/// What it does *not* do here is open a window on its own. A scheduled check
/// that finds something hands the news to `pendingVersion`, and the popover
/// shows it as one line. Sparkle's own window appears only after a click —
/// either that line or the button in Settings. This is Sparkle's "gentle
/// reminders" path, and it is why the background check is on by default: it
/// no longer costs the user an interruption.
///
/// Where the numbers live: `SUFeedURL` and `SUPublicEDKey` are written into the
/// bundle by `Scripts/make-app-bundle.sh`. There is no copy of them here — a
/// second copy is a second thing to go stale.
///
/// A build that is not a real bundle (`swift run`, or the app run straight out
/// of `.build`) has neither key. Sparkle then says so once on start and every
/// check reports "no feed"; nothing here pretends otherwise.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = UpdateController()

    /// Sparkle disables the menu item while it is already checking, and while
    /// the updater failed to start at all. Mirrored so SwiftUI can dim ours.
    @Published private(set) var canCheck = false
    /// The version a background check found and nobody has looked at yet, or
    /// nil. This is the whole notification: no badge is stored, no alert is
    /// posted, and it goes away as soon as the user has seen Sparkle's window.
    @Published private(set) var pendingVersion: String?
    /// The background check. On by default; the switch stays because a user who
    /// wants no network call at all should be able to say so.
    @Published var checksAutomatically: Bool {
        didSet {
            guard controller.updater.automaticallyChecksForUpdates != checksAutomatically else { return }
            controller.updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    /// Assigned after `super.init` because Sparkle takes its delegate at
    /// construction and that delegate is this object.
    private var controller: SPUStandardUpdaterController!
    private var observers: [NSKeyValueObservation] = []

    private override init() {
        checksAutomatically = false
        super.init()
        // `startUpdater` is what reads the Info.plist and schedules the
        // background check. A missing feed is reported through the delegate
        // below, not thrown — the app must still run without one.
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        controller.startUpdater()
        observers = [
            controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor in self?.canCheck = updater.canCheckForUpdates }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor in self?.checksAutomatically = updater.automaticallyChecksForUpdates }
            },
        ]
    }

    /// The user asked. Sparkle drives the whole conversation from here: found /
    /// not found, release notes, download, install, relaunch. Called for the
    /// button in Settings and for the popover line alike — an update Sparkle
    /// already found is brought back into focus rather than fetched again.
    func checkForUpdates() {
        // Its own window, so it must come to the front like the Settings one:
        // an accessory app puts nothing in the Dock to click.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// The feed the running bundle was built with, or nil in a bare binary.
    var feedURL: String? {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    }

    // MARK: - SPUUpdaterDelegate

    /// Sparkle reports a missing feed, an unreachable one and a bad signature
    /// through the same call. None of them is worth a modal on a background
    /// check — the user did not ask, and the app keeps working either way.
    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        NSLog("[updates] %@", error.localizedDescription)
    }

    // MARK: - SPUStandardUserDriverDelegate

    @objc nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// No. A check the user did not ask for must not take the screen. Saying so
    /// here is what makes Sparkle call `willHandleShowingUpdate` with `false`
    /// and leave the telling to us.
    @objc nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    /// `handleShowingUpdate` is true when the user asked — then Sparkle's window
    /// is the notification and a line under it would be a second copy of the
    /// same news.
    @objc nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        NSLog("[updates] found %@ (sparkle shows it: %@)", version, handleShowingUpdate ? "yes" : "no")
        Task { @MainActor [weak self] in
            self?.pendingVersion = handleShowingUpdate ? nil : version
        }
    }

    /// The user has the update in front of them, so the line has done its job —
    /// whether they install, skip, or close the window.
    @objc nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor [weak self] in self?.pendingVersion = nil }
    }

    /// Also reached when a check ends in an error, which is the case the line
    /// would otherwise outlive.
    @objc nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor [weak self] in self?.pendingVersion = nil }
    }
}
