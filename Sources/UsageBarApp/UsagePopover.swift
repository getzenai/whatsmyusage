import SwiftUI
import UsageBarCore

/// Popover body. Custom views — not disabled menu rows — so the type stays readable.
struct UsagePopoverView: View {
    let cards: [AccountCard]
    var onRename: (String, String) -> Void
    var onRefresh: () -> Void
    var onCookies: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if cards.isEmpty {
                Text("No account — open Settings to paste cookies.")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .padding(16)
            } else {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    if index > 0 { Divider().opacity(0.35) }
                    AccountCardView(card: card, onRename: onRename)
                }
            }

            Divider().opacity(0.35)
            HStack(spacing: 12) {
                Button("Refresh", action: onRefresh)
                Button("Settings…", action: onCookies)
                Spacer()
                Text(AppVersion.label)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Button("Quit", action: onQuit)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 360)
        .background(.background)
    }
}

private struct AccountCardView: View {
    let card: AccountCard
    var onRename: (String, String) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    private var displayName: String {
        AccountNames.name(for: card.trackingID, default: card.defaultName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if editing {
                    TextField("Account name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
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
                        .onTapGesture { beginEdit() }
                        .help("Click to rename")
                }
                Spacer(minLength: 8)
            }

            if let message = card.message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
            }

            ForEach(card.limits) { limit in
                LimitRow(limit: limit)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func beginEdit() {
        draft = displayName
        editing = true
    }

    private func commit() {
        guard editing else { return }
        editing = false
        nameFocused = false
        onRename(card.trackingID, draft)
    }
}

private struct LimitRow: View {
    let limit: Limit

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(limit.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if limit.locked == .locked {
                    Text("locked")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.red)
                }
                Text(BarPresentation.percentString(limit.utilization))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(4, geo.size.width * BarPresentation.filledFraction(limit.utilization)))
                }
            }
            .frame(height: 5)

            if let reset = limit.resetsAt {
                Text("resets \(ResetFormatting.remaining(until: reset))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var barColor: Color {
        switch BarPresentation.tone(of: limit) {
        case .critical: return .red
        case .warning: return .orange
        case .ok: return .green
        default: return .gray
        }
    }
}
