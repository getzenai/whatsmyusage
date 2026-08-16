import AppKit
import SwiftUI
import UsageBarCore

/// The badges, in their own window. They used to sit under the accounts in the
/// popover, which made the popover look like the point of the app was the game.
@MainActor
final class AchievementsWindowController {
    private var window: NSWindow?

    func show(_ achievements: [Achievements.Achievement]) {
        let view = AchievementsView(achievements: achievements)
        let hosting = NSHostingController(rootView: view)

        if let window {
            window.contentViewController = hosting
        } else {
            let window = NSWindow(contentViewController: hosting)
            window.title = "Achievements"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 380, height: 420))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct AchievementsView: View {
    let achievements: [Achievements.Achievement]

    private var earned: Int { achievements.filter(\.isEarned).count }

    /// Empty sections stay out until they have a badge. PR 2 will fill the rest.
    private var grouped: [(section: Achievements.Section, items: [Achievements.Achievement])] {
        Achievements.Section.allCases.compactMap { section in
            let items = achievements.filter { $0.kind.section == section }
            return items.isEmpty ? nil : (section, items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Achievements")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(earned)/\(achievements.count)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider().opacity(0.35)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(grouped, id: \.section) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.section.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            ForEach(group.items) { achievement in
                                AchievementRow(achievement: achievement)
                            }
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 340, minHeight: 260)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct AchievementRow: View {
    let achievement: Achievements.Achievement

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: achievement.isEarned ? "checkmark.seal.fill" : "lock")
                .font(.system(size: 12))
                .foregroundStyle(achievement.isEarned ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(achievement.title)
                    .font(.system(size: 13, weight: achievement.isEarned ? .medium : .regular))
                // Locked badges show what it takes; earned ones show the measured fact.
                Text(achievement.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .foregroundStyle(achievement.isEarned ? .primary : .secondary)
    }
}
