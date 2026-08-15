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
    var onPreferencesChanged: (() -> Void)?

    func show(startingAt step: OnboardingStep? = nil) {
        NSApp.setActivationPolicy(.regular)
        model.prefs = DisplayStore.load()
        if let step {
            model.step = step
        } else if !OnboardingState.didFinishWelcome {
            model.step = .welcome
        } else if !KeychainStore.load().isEmpty {
            model.step = .detected
            model.refreshKeychainSummary()
        } else {
            model.step = .paste
            model.refreshKeychainSummary()
        }
        if model.step != .welcome {
            model.refreshKeychainSummary()
        }
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
        window.setContentSize(NSSize(width: 640, height: 620))
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
        model.prefs = DisplayStore.load()
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
            close: { [weak self] in self?.window?.performClose(nil) },
            toggleLimit: { [weak self] trackingID, limitID in
                self?.mutatePrefs { $0.toggleLimit(trackingID: trackingID, limitID: limitID) }
            },
            toggleAccount: { [weak self] trackingID in
                self?.mutatePrefs { $0.toggleAccount(trackingID) }
            },
            moveAccount: { [weak self] trackingID, delta in
                self?.mutatePrefs { $0.move(trackingID: trackingID, by: delta, among: self?.model.cards ?? []) }
            },
            reorder: { [weak self] source, destination in
                self?.mutatePrefs { $0.move(from: source, to: destination, among: self?.model.cards ?? []) }
            },
            requestDelete: { [weak self] trackingID in
                self?.requestDelete(trackingID)
            },
            confirmDelete: { [weak self] in
                self?.confirmDelete()
            },
            cancelDelete: { [weak self] in
                self?.model.showingDeleteConfirm = false
                self?.model.pendingDeleteID = nil
                self?.model.pendingDeleteMessage = ""
                self?.syncRoot()
            },
            rename: { [weak self] trackingID, name in
                AccountNames.setName(name, for: trackingID)
                self?.syncRoot()
                self?.onPreferencesChanged?()
            },
            welcomeContinued: { [weak self] in
                OnboardingState.didFinishWelcome = true
                self?.model.refreshKeychainSummary()
                if !KeychainStore.load().isEmpty {
                    self?.onSaved?()
                    self?.model.step = .detected
                    self?.syncRoot()
                    return
                }
                self?.model.step = .paste
                self?.syncRoot()
            }
        )
    }

    private func mutatePrefs(_ body: (inout DisplayPreferences) -> Void) {
        body(&model.prefs)
        DisplayStore.save(model.prefs)
        syncRoot()
        onPreferencesChanged?()
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
        let trimmed = model.pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if !KeychainStore.load().isEmpty {
                model.step = .detected
                syncRoot()
                return
            }
            model.success = nil
            model.status = "Paste cookies first."
            syncRoot()
            return
        }
        do {
            let extracted = try SessionCookies.extractSessionKey(from: model.pasteText)
            KeychainStore.save(extracted)
            model.pasteText = ""
            model.success = "Kept only the session keys — \(summary(of: extracted))."
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
        KeychainStore.replace(CredentialStore())
        model.success = nil
        model.status = "Keychain cleared."
        model.cards = []
        model.refreshKeychainSummary()
        syncRoot()
        onSaved?()
    }

    private func requestDelete(_ trackingID: String) {
        let store = KeychainStore.load()
        let deletion = store.deletion(of: trackingID, cards: model.cards) { id, fallback in
            AccountNames.name(for: id, default: fallback)
        }
        model.pendingDeleteID = trackingID
        model.pendingDeleteMessage = deletion?.message
            ?? "Removes this login from the Keychain."
        model.showingDeleteConfirm = true
        syncRoot()
    }

    private func confirmDelete() {
        // Do not clear pendingDeleteID when the alert dismisses — SwiftUI sets
        // isPresented to false before the destructive button action runs.
        guard let trackingID = model.pendingDeleteID else { return }
        model.showingDeleteConfirm = false
        model.pendingDeleteID = nil
        model.pendingDeleteMessage = ""
        KeychainStore.remove(trackingID: trackingID)
        let store = KeychainStore.load()
        model.cards.removeAll { card in
            !store.accounts.contains { $0.owns(trackingID: card.trackingID) }
        }
        model.success = nil
        model.status = ""
        model.refreshKeychainSummary()
        syncRoot()
        onSaved?()
    }

    private func summary(of creds: ExtractedCredentials) -> String {
        var bits: [String] = []
        if !creds.claudeAccounts.isEmpty {
            bits.append(creds.claudeAccounts.count == 1 ? "Claude" : "Claude ×\(creds.claudeAccounts.count)")
        }
        if !creds.chatGPTAccounts.isEmpty {
            bits.append(creds.chatGPTAccounts.count == 1 ? "ChatGPT" : "ChatGPT ×\(creds.chatGPTAccounts.count)")
        }
        if !creds.grokAccounts.isEmpty {
            bits.append(creds.grokAccounts.count == 1 ? "Grok" : "Grok ×\(creds.grokAccounts.count)")
        }
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
    var prefs = DisplayPreferences()
    var pendingDeleteID: String?
    var pendingDeleteMessage: String = ""
    var showingDeleteConfirm = false

    func refreshKeychainSummary() {
        let store = KeychainStore.load()
        if store.isEmpty {
            keychainSummary = "No account in the Keychain yet."
            return
        }
        var bits: [String] = []
        let claude = store.accounts.filter { $0.claude != nil }.count
        let chatGPT = store.accounts.filter { $0.chatGPT != nil }.count
        let grok = store.accounts.filter { $0.grok != nil }.count
        if claude > 0 { bits.append(claude == 1 ? "Claude" : "Claude ×\(claude)") }
        if chatGPT > 0 { bits.append(chatGPT == 1 ? "ChatGPT" : "ChatGPT ×\(chatGPT)") }
        if grok > 0 { bits.append(grok == 1 ? "Grok" : "Grok ×\(grok)") }
        keychainSummary = bits.joined(separator: ", ") + " in the Keychain."
    }
}

struct OnboardingActions {
    var pasteFromClipboard: () -> Void
    var save: () -> Void
    var clear: () -> Void
    var close: () -> Void
    var toggleLimit: (String, String) -> Void
    var toggleAccount: (String) -> Void
    var moveAccount: (String, Int) -> Void
    var reorder: (IndexSet, Int) -> Void
    var requestDelete: (String) -> Void
    var confirmDelete: () -> Void
    var cancelDelete: () -> Void
    var rename: (String, String) -> Void
    var welcomeContinued: () -> Void
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
            Text("At a glance you can see how much longer your agents can keep working — Claude, ChatGPT, and Grok, including every organisation behind the same login.")
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text("On Continue, macOS will ask for Keychain access. The app uses it to store and read the session keys — nothing else.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            KeychainPromptPreview()
            Spacer(minLength: 0)
        }
    }

    private var paste: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste your cookies")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
            Text("Copy every cookie from the browser and paste them here. We extract only the ones we need to read usage — you do not have to pick them out.")
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
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
            Text("We already picked out the relevant cookies for you. Only those session keys are stored in the Keychain; everything else from the paste was thrown away. Drag a row to set the order of the popover and the pill. The eye hides a limit. Trash removes the whole login — every organisation that cookie feeds — and asks first.")
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
                List {
                    ForEach(model.prefs.ordered(model.cards)) { card in
                        DetectedCard(card: card, prefs: model.prefs, actions: actions)
                            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                            .listRowSeparator(.visible)
                            .listRowBackground(Color.clear)
                    }
                    .onMove { actions.reorder($0, $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer(minLength: 0)
        }
        .alert("Remove this login?", isPresented: $model.showingDeleteConfirm) {
            Button("Remove login", role: .destructive, action: actions.confirmDelete)
            Button("Cancel", role: .cancel, action: actions.cancelDelete)
        } message: {
            Text(model.pendingDeleteMessage)
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
            } else if model.step == .detected {
                Button("Add cookies") { model.step = .paste }
            }
            Text(AppVersion.label)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
            if model.step != .welcome {
                Button("Back") { go(-1) }
            }
            if model.step == .done {
                Button("Close") { actions.close() }
                    .keyboardShortcut(.defaultAction)
            } else if model.step == .paste {
                Button("Continue") { go(1) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { go(1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func go(_ delta: Int) {
        if model.step == .welcome, delta == 1 {
            actions.welcomeContinued()
            return
        }
        if model.step == .paste, delta == 1 {
            actions.save()
            return
        }
        let next = model.step.rawValue + delta
        guard let step = OnboardingStep(rawValue: next) else { return }
        model.step = step
    }

    private func title(_ step: OnboardingStep) -> String {
        switch step {
        case .welcome: "Welcome"
        case .paste: "Paste cookies"
        case .detected: "Settings"
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

        Copy the whole table. Continue stores only the session keys.
        """
    }
}

private struct DetectedCard: View {
    let card: AccountCard
    let prefs: DisplayPreferences
    let actions: OnboardingActions
    @State private var draft: String = ""
    @State private var editing = false
    @FocusState private var nameFocused: Bool

    private var displayName: String {
        AccountNames.name(for: card.trackingID, default: card.defaultName)
    }

    private var accountVisible: Bool {
        prefs.isAccountVisible(card.trackingID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .help("Drag to reorder")

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
                        .foregroundStyle(accountVisible ? Color.primary : Color.secondary)
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
                eyeButton(
                    visible: accountVisible,
                    help: accountVisible ? "Hide this account from the bar" : "Show this account in the bar"
                ) {
                    actions.toggleAccount(card.trackingID)
                }
                Button {
                    actions.requestDelete(card.trackingID)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Remove the login this card belongs to")
            }
            ForEach(card.limits) { limit in
                let visible = prefs.isLimitVisible(trackingID: card.trackingID, limitID: limit.id)
                HStack {
                    Text(limit.label)
                        .font(.system(size: 12))
                        .foregroundStyle(visible ? Color.primary : Color.secondary)
                    Spacer()
                    Text(BarPresentation.percentString(limit.utilization))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(visible ? Color.primary : Color.secondary)
                    eyeButton(
                        visible: visible,
                        help: visible ? "Hide this limit" : "Show this limit"
                    ) {
                        actions.toggleLimit(card.trackingID, limit.id)
                    }
                }
                .opacity(visible ? 1 : 0.45)
            }
        }
        .padding(12)
        .opacity(accountVisible ? 1 : 0.55)
    }

    private func eyeButton(visible: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: visible ? "eye" : "eye.slash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(visible ? Color.secondary : Color.primary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func commit() {
        guard editing else { return }
        editing = false
        nameFocused = false
        actions.rename(card.trackingID, draft)
    }
}

/// Visual stand-in for the macOS Keychain sheet. People skip the paragraph;
/// they recognise the buttons.
private struct KeychainPromptPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI Usage Bar wants to use your confidential information stored in “credentials” in your keychain.")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("That is where session keys are stored and read. Always Allow is fine.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                previewButton("Always Allow")
                previewButton("Deny")
                previewButton("Allow")
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private func previewButton(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
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
