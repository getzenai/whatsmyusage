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
/// Where the numbers live: `SUFeedURL` and `SUPublicEDKey` are written into the
/// bundle by `Scripts/make-app-bundle.sh`. There is no copy of them here — a
/// second copy is a second thing to go stale.
///
/// A build that is not a real bundle (`swift run`, or the app run straight out
/// of `.build`) has neither key. Sparkle then says so once on start and every
/// check reports "no feed"; nothing here pretends otherwise.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateController()

    /// Sparkle disables the menu item while it is already checking, and while
    /// the updater failed to start at all. Mirrored so SwiftUI can dim ours.
    @Published private(set) var canCheck = false
    /// The background check. Off until someone turns it on: the first update
    /// check should be a thing the user asked for, not a surprise on first
    /// launch. Sparkle would otherwise ask on its own with a modal on day one.
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
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
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
    /// not found, release notes, download, install, relaunch.
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
}
