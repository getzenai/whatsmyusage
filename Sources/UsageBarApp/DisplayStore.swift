import Foundation
import UsageBarCore

enum OnboardingState {
    private static let welcomeKey = "didFinishWelcome"

    static var didFinishWelcome: Bool {
        get { UserDefaults.standard.bool(forKey: welcomeKey) }
        set { UserDefaults.standard.set(newValue, forKey: welcomeKey) }
    }
}

/// Visibility and order. Not secret — cookies stay in the Keychain.
enum DisplayStore {
    private static let hiddenLimitsKey = "hiddenLimitKeys"
    private static let hiddenAccountsKey = "hiddenAccountIDs"
    private static let orderKey = "accountOrder"

    static func load() -> DisplayPreferences {
        DisplayPreferences(
            hiddenLimitKeys: Set(UserDefaults.standard.stringArray(forKey: hiddenLimitsKey) ?? []),
            hiddenAccountIDs: Set(UserDefaults.standard.stringArray(forKey: hiddenAccountsKey) ?? []),
            accountOrder: UserDefaults.standard.stringArray(forKey: orderKey) ?? []
        )
    }

    static func save(_ prefs: DisplayPreferences) {
        UserDefaults.standard.set(Array(prefs.hiddenLimitKeys).sorted(), forKey: hiddenLimitsKey)
        UserDefaults.standard.set(Array(prefs.hiddenAccountIDs).sorted(), forKey: hiddenAccountsKey)
        UserDefaults.standard.set(prefs.accountOrder, forKey: orderKey)
    }
}
