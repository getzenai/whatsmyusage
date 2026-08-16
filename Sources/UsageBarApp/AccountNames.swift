import Foundation
import UsageBarCore

/// Local display names. Cookies stay in the Keychain; names are not secret.
enum AccountNames {
    private static let key = "accountDisplayNames"

    static func name(for trackingID: String, default defaultName: String) -> String {
        let custom = stored()[trackingID]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let custom, !custom.isEmpty { return custom }
        return defaultName
    }

    static func setName(_ name: String, for trackingID: String) {
        var map = stored()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            map.removeValue(forKey: trackingID)
        } else {
            map[trackingID] = trimmed
        }
        UserDefaults.standard.set(map, forKey: key)
    }

    static func all() -> [String: String] {
        stored()
    }

    /// So the CLI can print the onboarding name without reading the log.
    static func persistDefaultNames(_ cards: [AccountCard]) {
        var map: [String: String] = [:]
        for card in cards {
            map[card.trackingID] = card.defaultName
        }
        UserDefaults.standard.set(map, forKey: AccountDisplayNames.defaultKey)
    }

    /// Copy a custom name onto the new tracking id after a storage upgrade.
    static func remap(from old: String, to new: String) {
        guard old != new, let name = stored()[old] else { return }
        setName(name, for: new)
    }

    private static func stored() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
