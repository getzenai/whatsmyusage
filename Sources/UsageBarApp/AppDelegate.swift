import AppKit
import UsageBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private let settings = SettingsController()
    private let client = UsageClient()
    private var refreshTimer: Timer?
    private var inflight: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StatusItemController()
        controller.onRefresh = { [weak self] in self?.refresh() }
        controller.onOpenSettings = { [weak self] in self?.settings.show() }
        controller.onQuit = { NSApp.terminate(nil) }
        statusItem = controller
        settings.onSaved = { [weak self] in self?.refresh() }

        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 30
        refreshTimer = timer

        if KeychainStore.load().isEmpty {
            settings.show()
        }
    }

    private func refresh() {
        inflight?.cancel()
        inflight = Task { [weak self] in
            guard let self else { return }
            let creds = KeychainStore.load()
            if creds.isEmpty {
                self.statusItem?.update(outcomes: [])
                return
            }
            let byProvider = await self.client.refresh(using: creds)
            if Task.isCancelled { return }
            let outcomes = Provider.allCases.flatMap { byProvider[$0] ?? [] }
            self.statusItem?.update(outcomes: outcomes)
        }
    }
}
