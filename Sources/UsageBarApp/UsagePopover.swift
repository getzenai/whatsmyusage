import SwiftUI
import UsageBarCore

/// Popover body. Custom views — not disabled menu rows — so the type stays readable.
struct UsagePopoverView: View {
    let cards: [AccountCard]
    var history: PopoverHistory = .none
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

            if !history.isEmpty {
                Divider().opacity(0.35)
                HistorySection(history: history)
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

/// The past, under the accounts: what you are waiting on, and the badges the log
/// earned. Collapsed by default — this is the fun part, not the point of the app.
private struct HistorySection: View {
    let history: PopoverHistory
    @AppStorage("showAchievements") private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(history.waits) { wait in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Waiting")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    // The measured wait, not now − since: the last reading is the last
                    // thing we know. Inventing the minutes since would be guessing.
                    Text(wait.duration.hoursAndMinutes)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                    Text("for \(wait.label)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                }
            }

            if !history.achievements.isEmpty {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Achievements")
                            .font(.system(size: 12, weight: .medium))
                        Text("\(history.earnedCount)/\(history.achievements.count)")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)

                if expanded {
                    ForEach(history.achievements) { achievement in
                        AchievementRow(achievement: achievement)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct AchievementRow: View {
    let achievement: Achievements.Achievement

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: achievement.isEarned ? "checkmark.seal.fill" : "lock")
                .font(.system(size: 11))
                .foregroundStyle(achievement.isEarned ? Color.accentColor : Color.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(achievement.title)
                    .font(.system(size: 12, weight: achievement.isEarned ? .medium : .regular))
                // Locked badges show what it takes; earned ones show the measured fact.
                Text(achievement.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .foregroundStyle(achievement.isEarned ? .primary : .secondary)
    }
}
