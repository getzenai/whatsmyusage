import AppKit
import SwiftUI
import UsageBarCore

/// Paste-only text view. Chrome's cookie table often lands as RTF/HTML on the
/// pasteboard; the stock NSTextView paste then no-ops in an accessory app
/// that has no Edit menu. Always take the plain-string flavor.
final class PlainPasteTextView: NSTextView {
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

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case paste
    case detected
    case done
}

/// First-run wizard: welcome → paste → detected → done.
@MainActor
final class SettingsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var hosting: NSHostingController<OnboardingRoot>?
    private var model = OnboardingModel()
    var onSaved: (() -> Void)?

    func show() {
        NSApp.setActivationPolicy(.regular)
        model.step = KeychainStore.load().isEmpty ? .welcome : .paste
        model.refreshKeychainSummary()
        if let window {
            syncRoot()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let root = OnboardingRoot(model: model, actions: actions())
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "AI Usage Bar"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 640, height: 560))
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.hosting = hosting
        self.window = window
    }

    func didRefresh(byProvider: [Provider: [UsageOutcome]]) {
        model.cards = BarPresentation.cards(byProvider: byProvider)
        if model.advanceAfterRefresh {
            model.advanceAfterRefresh = false
            model.step = model.cards.isEmpty ? .paste : .detected
            syncRoot()
        } else if model.step == .detected {
            syncRoot()
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.pasteText = ""
        NSApp.setActivationPolicy(.accessory)
    }

    private func actions() -> OnboardingActions {
        OnboardingActions(
            pasteFromClipboard: { [weak self] in self?.pasteFromClipboard() },
            save: { [weak self] in self?.save() },
            clear: { [weak self] in self?.clearAll() },
            close: { [weak self] in self?.window?.performClose(nil) }
        )
    }

    private func syncRoot() {
        hosting?.rootView = OnboardingRoot(model: model, actions: actions())
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            model.status = "Clipboard is empty."
            model.success = nil
            syncRoot()
            return
        }
        if model.pasteText.isEmpty {
            model.pasteText = text
        } else if model.pasteText.hasSuffix("\n") {
            model.pasteText += text
        } else {
            model.pasteText += "\n" + text
        }
        syncRoot()
    }

    private func save() {
        do {
            let extracted = try SessionCookies.extractSessionKey(from: model.pasteText)
            KeychainStore.save(extracted)
            model.pasteText = ""
            model.success = "Saved to the Keychain — \(summary(of: extracted))."
            model.status = ""
            model.refreshKeychainSummary()
            model.advanceAfterRefresh = true
            syncRoot()
            onSaved?()
        } catch {
            model.success = nil
            model.status = "No key found. Claude: sessionKey. ChatGPT: session-token.0/.1. Grok: sso."
            syncRoot()
        }
    }

    private func clearAll() {
        KeychainStore.replace(ExtractedCredentials())
        model.success = nil
        model.status = "Keychain cleared."
        model.cards = []
        model.refreshKeychainSummary()
        syncRoot()
        onSaved?()
    }

    private func summary(of creds: ExtractedCredentials) -> String {
        var bits: [String] = []
        if creds.claude != nil { bits.append("Claude") }
        if let gpt = creds.chatGPT {
            let n = gpt.parts.isEmpty ? 1 : gpt.parts.count
            bits.append("ChatGPT (\(n) part\(n == 1 ? "" : "s"))")
        }
        if creds.grok != nil { bits.append("Grok") }
        return bits.isEmpty ? "nothing" : bits.joined(separator: ", ")
    }
}

@MainActor
@Observable
final class OnboardingModel {
    var step: OnboardingStep = .welcome
    var pasteText: String = ""
    var status: String = ""
    var success: String?
    var keychainSummary: String = "No account in the Keychain yet."
    var cards: [AccountCard] = []
    var advanceAfterRefresh = false

    func refreshKeychainSummary() {
        let creds = KeychainStore.load()
        if creds.isEmpty {
            keychainSummary = "No account in the Keychain yet."
            return
        }
        var bits: [String] = []
        if creds.claude != nil { bits.append("Claude") }
        if creds.chatGPT != nil { bits.append("ChatGPT") }
        if creds.grok != nil { bits.append("Grok") }
        keychainSummary = bits.joined(separator: ", ") + " in the Keychain."
    }
}

struct OnboardingActions {
    var pasteFromClipboard: () -> Void
    var save: () -> Void
    var clear: () -> Void
    var close: () -> Void
}

struct OnboardingRoot: View {
    @Bindable var model: OnboardingModel
    let actions: OnboardingActions

    var body: some View {
        VStack(spacing: 0) {
            stepHeader
            Divider().opacity(0.35)
            Group {
                switch model.step {
                case .welcome: welcome
                case .paste: paste
                case .detected: detected
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
            Divider().opacity(0.35)
            footer
        }
        .frame(minWidth: 620, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var stepHeader: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                let active = model.step == step
                Text(title(step))
                    .font(.system(size: 11, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.primary : Color.secondary)
                if step != .done {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to AI Usage Bar")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
            Text("Every AI subscription, in the menu bar. One glance tells you whether you can still work — Claude, ChatGPT, and Grok, including every organisation behind the same login.")
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Paste cookies once. Only the session keys go into the Keychain. The rest of the paste is thrown away.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private var paste: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste your cookies")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
            Text(instructions)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            CookieEditor(text: $model.pasteText)
                .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
            if let success = model.success {
                Label(success, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 13, weight: .medium))
            }
            if !model.status.isEmpty {
                Text(model.status)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
            }
            Text(model.keychainSummary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var detected: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Here’s what we found")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
            Text("One card per account. Click a name to rename it — useful when two Claude organisations would otherwise look the same.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let success = model.success {
                Label(success, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 13, weight: .medium))
            }
            if model.cards.isEmpty {
                Text("Saved, but no live usage yet. Check the paste, or continue and refresh from the bar.")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.cards) { card in
                            DetectedCard(card: card)
                            Divider().opacity(0.3)
                        }
                    }
                }
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer(minLength: 0)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("You’re set")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
            Text("Close this window and look at the menu bar. Each coloured slot is one account. Click the pill for bars, reset times, and names.")
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Link(destination: URL(string: "https://github.com/sponsors/getzenai")!) {
                Label("Support the developers on GitHub Sponsors", systemImage: "heart.fill")
                    .font(.system(size: 13, weight: .medium))
            }
            Link(destination: URL(string: "https://github.com/getzenai/ai_usage_bar")!) {
                Text("github.com/getzenai/ai_usage_bar")
                    .font(.system(size: 12))
            }
            Spacer()
        }
    }

    private var footer: some View {
        HStack {
            if model.step == .paste {
                Button("Paste", action: actions.pasteFromClipboard)
                Button("Save to Keychain", action: actions.save)
                    .keyboardShortcut(.defaultAction)
                Button("Clear Keychain", action: actions.clear)
            }
            Spacer()
            if model.step != .welcome {
                Button("Back") { go(-1) }
            }
            if model.step == .done {
                Button("Close") { actions.close() }
                    .keyboardShortcut(.defaultAction)
            } else if model.step == .paste {
                Button("Continue") { go(1) }
            } else {
                Button("Continue") { go(1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func go(_ delta: Int) {
        let next = model.step.rawValue + delta
        guard let step = OnboardingStep(rawValue: next) else { return }
        model.step = step
    }

    private func title(_ step: OnboardingStep) -> String {
        switch step {
        case .welcome: "Welcome"
        case .paste: "Paste cookies"
        case .detected: "Detected"
        case .done: "Done"
        }
    }

    private var instructions: String {
        """
        Chrome, Edge, or Brave
        1. Log in to the provider (claude.ai, chatgpt.com, grok.com).
        2. Open DevTools: right-click → Inspect, or View → Developer → Developer Tools, or ⌥⌘I.
        3. Application → Storage → Cookies → the site. claude.ai and a.claude.ai are separate lists — copy both.
        4. Click any cookie row, then ⌘A ⌘C.
        5. Paste here (⌘V or Paste). Repeat for each provider, or paste them all at once.

        Safari: Safari → Settings → Advanced → “Show features for web developers”, then Develop → Show Web Inspector → Storage → Cookies.
        Firefox: right-click → Inspect → Storage → Cookies.

        Claude needs sessionKey, ChatGPT the numbered session-token.* parts, Grok sso.
        """
    }
}

private struct DetectedCard: View {
    let card: AccountCard
    @State private var draft: String = ""
    @State private var editing = false
    @FocusState private var nameFocused: Bool

    private var displayName: String {
        AccountNames.name(for: card.trackingID, default: card.defaultName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if editing {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit { commit() }
                        .onChange(of: nameFocused) { _, focused in
                            if !focused { commit() }
                        }
                        .onDisappear { commit() }
                        .onAppear { nameFocused = true }
                } else {
                    Text(displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .onTapGesture {
                            draft = displayName
                            editing = true
                        }
                }
                Spacer()
                Text(card.provider.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if let utilization = card.utilization {
                    Text(BarPresentation.percentString(utilization))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.primary)
                }
            }
            ForEach(card.limits.prefix(4)) { limit in
                HStack {
                    Text(limit.label)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(BarPresentation.percentString(limit.utilization))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding(12)
    }

    private func commit() {
        guard editing else { return }
        editing = false
        nameFocused = false
        AccountNames.setName(draft, for: card.trackingID)
    }
}

private struct CookieEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let editor = PlainPasteTextView()
        editor.isRichText = false
        editor.importsGraphics = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.delegate = context.coordinator
        editor.string = text
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 580, height: CGFloat.greatestFiniteMagnitude)
        context.coordinator.editor = editor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? PlainPasteTextView else { return }
        if editor.string != text {
            editor.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var editor: PlainPasteTextView?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}
