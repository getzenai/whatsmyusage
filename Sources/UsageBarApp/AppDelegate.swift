import AppKit
import UsageBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private let settings = SettingsController()
    private let client = UsageClient()
    private let statusClient = ServiceStatusClient()
    private var refreshTimer: Timer?
    private var inflight: Task<Void, Never>?
    private var statusInflight: Task<Void, Never>?
    private let usageLog = UsageLogWriter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        DefaultsMigration.run()
        installEditMenu()
        // Constructed at launch, not on first use: the scheduled background
        // check only exists while the updater does.
        _ = UpdateController.shared
        let controller = StatusItemController()
        controller.onRefresh = { [weak self] in self?.refresh() }
        controller.onOpenSettings = { [weak self] in self?.settings.show() }
        controller.onQuit = { NSApp.terminate(nil) }
        controller.historyProvider = { [weak self] in self?.usageLog.history() ?? .none }
        controller.pillStyle = DisplayStore.load().pill
        controller.onRename = { [weak controller] id, name in
            AccountNames.setName(name, for: id)
            controller?.refreshTooltip()
        }
        statusItem = controller
        settings.onSaved = { [weak self] in self?.refresh() }
        settings.onPreferencesChanged = { [weak self] in self?.reapply() }
        // Switching a source back on has nothing cached to show — that read was
        // never made. Ask again instead of leaving the line blank until the
        // next tick.
        settings.onStatusPreferencesChanged = { [weak self] in
            self?.applyStatus()
            self?.refreshStatus()
        }

        let timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 30
        refreshTimer = timer

        if !OnboardingState.didFinishWelcome {
            settings.show(startingAt: .welcome)
            return
        }

        refresh()
        if KeychainStore.load().isEmpty {
            settings.show()
        }
    }

    /// Accessory apps have no default Edit menu, so ⌘V never reaches a text view.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Quit \(AppIdentity.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    private var lastByProvider: [Provider: [UsageOutcome]] = [:]
    /// Last successful voucher read per tracking id. A miss does not clear this;
    /// a successful `.none` does.
    private var lastResetAvailable: [String: Int] = [:]
    private var lastStatusReads: [StatusRead] = []
    private var lastStatusCheckedAt: Date?

    @objc private func openSettings() {
        settings.show()
    }

    @objc private func checkForUpdates() {
        UpdateController.shared.checkForUpdates()
    }

    /// The status pages are read next to the numbers, not after them: they
    /// answer a different question and neither should wait for the other.
    private func refreshStatus() {
        statusInflight?.cancel()
        statusInflight = Task { [weak self] in
            guard let self else { return }
            let prefs = StatusStore.load()
            let reads = await self.statusClient.read(preferences: prefs)
            if Task.isCancelled { return }
            self.lastStatusReads = reads
            // Nothing was asked, so nothing was checked — the line must not
            // print a time that stands for no reading.
            self.lastStatusCheckedAt = reads.isEmpty ? nil : Date()
            self.applyStatus()
        }
    }

    private func applyStatus() {
        let digest = StatusDigest.of(
            reads: lastStatusReads,
            preferences: StatusStore.load(),
            checkedAt: lastStatusCheckedAt
        )
        statusItem?.update(status: digest)
        settings.didReadStatus(lastStatusReads)
    }

    private func refresh() {
        guard OnboardingState.didFinishWelcome else { return }
        refreshStatus()
        inflight?.cancel()
        inflight = Task { [weak self] in
            guard let self else { return }
            let store = KeychainStore.load()
            if store.isEmpty {
                self.lastByProvider = [:]
                self.lastResetAvailable = [:]
                self.statusItem?.update(outcomes: [])
                self.settings.didRefresh(byProvider: [:])
                return
            }
            let result = await self.client.refresh(using: store)
            if Task.isCancelled { return }
            if !result.claudeOrgIDsByAccountID.isEmpty {
                KeychainStore.recordClaudeOrgs(result.claudeOrgIDsByAccountID)
            }
            self.lastByProvider = result.byProvider
            // Log the reading, not the display: `apply` also runs when only a
            // preference changed, and that is not a new measurement.
            self.usageLog.record(result.byProvider)
            self.apply(result.byProvider)

            // Vouchers after the numbers. A slow or failing extra call must
            // not hold the limits — they are already on screen.
            let resets = await self.client.fetchResetCredits(using: store)
            if Task.isCancelled { return }
            for (id, read) in resets {
                if let count = read.count {
                    self.lastResetAvailable[id] = count
                } else {
                    self.lastResetAvailable.removeValue(forKey: id)
                }
            }
            self.apply(self.lastByProvider)
        }
    }

    private func reapply() {
        apply(lastByProvider)
        applyStatus()
    }

    private func apply(_ byProvider: [Provider: [UsageOutcome]]) {
        let raw = BarPresentation.cards(byProvider: byProvider)
        AccountNames.persistDefaultNames(raw)
        let prefs = DisplayStore.load()
        statusItem?.pillStyle = prefs.pill
        let shown = prefs.applied(to: raw).map { card in
            card.withResetAvailable(lastResetAvailable[card.trackingID])
        }
        statusItem?.update(cards: shown, byProvider: byProvider)
        settings.didRefresh(byProvider: byProvider)
    }
}
