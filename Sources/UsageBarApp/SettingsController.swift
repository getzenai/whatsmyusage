import AppKit
import UsageBarCore

/// Paste-only text view. Chrome's cookie table often lands as RTF/HTML on the
/// pasteboard; the stock NSTextView paste then no-ops in an accessory app
/// that has no Edit menu. Always take the plain-string flavor.
private final class PlainPasteTextView: NSTextView {
    override func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        insertText(text, replacementRange: selectedRange())
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers == "v"
        else { return super.performKeyEquivalent(with: event) }
        paste(nil)
        return true
    }
}

/// Paste window. The user drops a cookie table; we extract keys and put them
/// in the Keychain. The raw paste never leaves this window.
@MainActor
final class SettingsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let editor = PlainPasteTextView()
    private let status = NSTextField(labelWithString: "")
    var onSaved: (() -> Void)?

    func show() {
        NSApp.setActivationPolicy(.regular)
        if let window {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(editor)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
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
        Chrome, Edge, or Brave
        1. Log in to the provider (claude.ai, chatgpt.com, grok.com).
        2. Open DevTools: right-click → Inspect, or View → Developer → Developer Tools, or ⌥⌘I.
        3. Application → Storage → Cookies → the site. claude.ai and a.claude.ai are separate lists — copy both.
        4. Click any cookie row, then ⌘A ⌘C.
        5. Paste here (⌘V or the Paste button). Repeat for each provider, or paste them all at once.

        Safari: Safari → Settings → Advanced → “Show features for web developers”, then Develop → Show Web Inspector → Storage → Cookies.
        Firefox: right-click → Inspect → Storage → Cookies.

        Claude needs sessionKey, ChatGPT the numbered session-token.* parts, Grok sso. The paste is not saved — only the keys go into the Keychain.
        """)
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.font = .systemFont(ofSize: 11)

        editor.isRichText = false
        editor.importsGraphics = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.frame = NSRect(x: 0, y: 0, width: 580, height: 180)
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
        editor.textContainer?.containerSize = NSSize(width: 580, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true

        status.translatesAutoresizingMaskIntoConstraints = false

        let paste = NSButton(title: "Paste", target: self, action: #selector(pasteFromClipboard))
        paste.translatesAutoresizingMaskIntoConstraints = false
        let save = NSButton(title: "Save to Keychain", target: self, action: #selector(save))
        save.translatesAutoresizingMaskIntoConstraints = false
        let clear = NSButton(title: "Clear Keychain", target: self, action: #selector(clearAll))
        clear.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(hint)
        content.addSubview(scroll)
        content.addSubview(status)
        content.addSubview(paste)
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
            status.trailingAnchor.constraint(lessThanOrEqualTo: paste.leadingAnchor, constant: -8),
            status.centerYAnchor.constraint(equalTo: save.centerYAnchor),

            save.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            save.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            clear.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -8),
            clear.centerYAnchor.constraint(equalTo: save.centerYAnchor),

            paste.trailingAnchor.constraint(equalTo: clear.leadingAnchor, constant: -8),
            paste.centerYAnchor.constraint(equalTo: save.centerYAnchor),
        ])

        refreshStatus()
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        editor.string = ""
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            status.stringValue = "Clipboard is empty."
            return
        }
        // Append: "Repeat for each provider" would otherwise wipe the first paste.
        if editor.string.isEmpty {
            editor.string = text
        } else if editor.string.hasSuffix("\n") {
            editor.string += text
        } else {
            editor.string += "\n" + text
        }
        editor.scrollToEndOfDocument(nil)
        window?.makeFirstResponder(editor)
    }

    @objc private func save() {
        let pasted = editor.string
        do {
            let extracted = try SessionCookies.extractSessionKey(from: pasted)
            KeychainStore.save(extracted)
            editor.string = ""
            status.stringValue = summary(of: extracted, verb: "saved")
            onSaved?()
        } catch {
            status.stringValue = "No key found. Claude: sessionKey. ChatGPT: session-token.0/.1. Grok: sso."
        }
    }

    @objc private func clearAll() {
        KeychainStore.replace(ExtractedCredentials())
        status.stringValue = "Keychain cleared."
        onSaved?()
    }

    private func refreshStatus() {
        let creds = KeychainStore.load()
        if creds.isEmpty {
            status.stringValue = "No account in the Keychain yet."
        } else {
            status.stringValue = summary(of: creds, verb: "in the Keychain")
        }
    }

    private func summary(of creds: ExtractedCredentials, verb: String) -> String {
        var bits: [String] = []
        if creds.claude != nil { bits.append("Claude") }
        if let gpt = creds.chatGPT {
            let n = gpt.parts.isEmpty ? 1 : gpt.parts.count
            bits.append("ChatGPT (\(n) part\(n == 1 ? "" : "s"))")
        }
        if creds.grok != nil { bits.append("Grok") }
        return bits.joined(separator: ", ") + " \(verb)."
    }
}
