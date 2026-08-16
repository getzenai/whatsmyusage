import Foundation

/// Names the CLI can print. Custom names live in the app's UserDefaults;
/// onboarding defaults are written on each refresh. The log never stores either.
public enum AccountDisplayNames {
    public static let suiteName = "com.whatsmyusage.app"
    public static let customKey = "accountDisplayNames"
    public static let defaultKey = "accountDefaultNames"

    public static func maps(from defaults: UserDefaults) -> (
        custom: [String: String],
        defaults: [String: String]
    ) {
        (stringMap(defaults.object(forKey: customKey)), stringMap(defaults.object(forKey: defaultKey)))
    }

    public static func loadFromAppSuite() -> (custom: [String: String], defaults: [String: String]) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return ([:], [:]) }
        return maps(from: defaults)
    }

    /// Exact `trackingID` only — a leftover `chatGPT` key must not match a UUID.
    /// Order: custom name → onboarding default → `claude #2 (3d9b381c)`.
    public static func resolve(
        trackingID: String,
        provider: Provider,
        custom: [String: String],
        defaults: [String: String],
        peers: [String]
    ) -> String {
        if let name = cleaned(custom[trackingID]) { return name }
        if let name = cleaned(defaults[trackingID]) { return name }
        return fallback(trackingID: trackingID, provider: provider, peers: peers)
    }

    public static func fallback(trackingID: String, provider: Provider, peers: [String]) -> String {
        let sorted = Set(peers + [trackingID]).sorted()
        let index = (sorted.firstIndex(of: trackingID) ?? 0) + 1
        let short = String(trackingID.prefix(8))
        return "\(provider.rawValue) #\(index) (\(short))"
    }

    public static func peers(
        for trackingID: String,
        provider: Provider,
        accounts: [(trackingID: String, provider: Provider)]
    ) -> [String] {
        accounts.filter { $0.provider == provider }.map(\.trackingID)
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringMap(_ object: Any?) -> [String: String] {
        guard let raw = object as? [String: Any] else { return [:] }
        var map: [String: String] = [:]
        for (key, value) in raw {
            if let string = value as? String { map[key] = string }
        }
        return map
    }
}
