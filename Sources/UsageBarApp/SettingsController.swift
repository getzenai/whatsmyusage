import AppKit
import UsageBarCore

/// Paste window. The user drops a cookie table; we extract keys and put them
/// in the Keychain. The raw paste never leaves this window.
@MainActor
final class SettingsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let editor = NSTextView()
    private let status = NSTextField(labelWithString: "")
    var onSaved: (() -> Void)?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cookies"
        window.delegate = self
        window.isReleasedWhenClosed = false

        let content = NSView(frame: window.contentView!.bounds)
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = content

        let hint = NSTextField(wrappingLabelWithString: """
        Cookie-Tabelle aus dem Browser hier einfügen (Safari: Einstellungen → Datenschutz → Cookies, oder DevTools). \
        Claude braucht sessionKey, ChatGPT die nummerierten session-token.*-Teile, Grok sso. \
        Mehrere Anbieter in einem Paste sind in Ordnung. Der Text wird nicht gespeichert — nur die erkannten Schlüssel wandern in die Keychain.
        """)
        hint.translatesAutoresizingMaskIntoConstraints = false

        editor.isRichText = false
        editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.frame = NSRect(x: 0, y: 0, width: 520, height: 200)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = editor
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.containerSize = NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true

        status.translatesAutoresizingMaskIntoConstraints = false

        let save = NSButton(title: "In Keychain legen", target: self, action: #selector(save))
        save.translatesAutoresizingMaskIntoConstraints = false
        let clear = NSButton(title: "Keychain leeren", target: self, action: #selector(clearAll))
        clear.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(hint)
        content.addSubview(scroll)
        content.addSubview(status)
        content.addSubview(save)
        content.addSubview(clear)

        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -12),

            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(lessThanOrEqualTo: clear.leadingAnchor, constant: -8),
            status.centerYAnchor.constraint(equalTo: save.centerYAnchor),

            save.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            save.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            clear.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -8),
            clear.centerYAnchor.constraint(equalTo: save.centerYAnchor),
        ])

        refreshStatus()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        editor.string = ""
    }

    @objc private func save() {
        let pasted = editor.string
        do {
            let extracted = try SessionCookies.extractSessionKey(from: pasted)
            KeychainStore.save(extracted)
            editor.string = ""
            status.stringValue = summary(of: extracted, verb: "gespeichert")
            onSaved?()
        } catch {
            status.stringValue = "Kein Schlüssel erkannt. Claude: sessionKey. ChatGPT: session-token.0/.1. Grok: sso."
        }
    }

    @objc private func clearAll() {
        KeychainStore.replace(ExtractedCredentials())
        status.stringValue = "Keychain geleert."
        onSaved?()
    }

    private func refreshStatus() {
        let creds = KeychainStore.load()
        if creds.isEmpty {
            status.stringValue = "Noch kein Konto in der Keychain."
        } else {
            status.stringValue = summary(of: creds, verb: "in der Keychain")
        }
    }

    private func summary(of creds: ExtractedCredentials, verb: String) -> String {
        var bits: [String] = []
        if creds.claude != nil { bits.append("Claude") }
        if let gpt = creds.chatGPT {
            let n = gpt.parts.isEmpty ? 1 : gpt.parts.count
            bits.append("ChatGPT (\(n) Teil\(n == 1 ? "" : "e"))")
        }
        if creds.grok != nil { bits.append("Grok") }
        return bits.joined(separator: ", ") + " \(verb)."
    }
}
