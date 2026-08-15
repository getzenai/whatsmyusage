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
        installEditMenu()
        let controller = StatusItemController()
        controller.onRefresh = { [weak self] in self?.refresh() }
        controller.onOpenSettings = { [weak self] in self?.settings.show() }
        controller.onQuit = { NSApp.terminate(nil) }
        controller.onRename = { [weak controller] id, name in
            AccountNames.setName(name, for: id)
            controller?.refreshTooltip()
        }
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

    /// Accessory apps have no default Edit menu, so ⌘V never reaches a text view.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit AI Usage Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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

    private func refresh() {
        inflight?.cancel()
        inflight = Task { [weak self] in
            guard let self else { return }
            let creds = KeychainStore.load()
            if creds.isEmpty {
                self.statusItem?.update(outcomes: [])
                self.settings.didRefresh(byProvider: [:])
                return
            }
            let byProvider = await self.client.refresh(using: creds)
            if Task.isCancelled { return }
            self.statusItem?.update(byProvider: byProvider)
            self.settings.didRefresh(byProvider: byProvider)
        }
    }
}
