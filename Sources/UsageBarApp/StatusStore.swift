import Foundation
import UsageBarCore

/// Where the Status Tracking settings live. Same suite as the display
/// preferences, so the CLI could read them too.
enum StatusStore {
    private static let enabledKey = "statusTrackingEnabled"
    private static let disabledSourcesKey = "statusDisabledSources"
    private static let watchedComponentsKey = "statusWatchedComponents"

    static func load() -> StatusPreferences {
        let defaults = UserDefaults.standard
        // Absent means never answered, and the answer we ship with is "on".
        // `bool(forKey:)` would read a fresh install as off.
        let enabled = defaults.object(forKey: enabledKey) as? Bool ?? true
        let disabled = Set((defaults.stringArray(forKey: disabledSourcesKey) ?? []).compactMap(StatusSource.init(rawValue:)))
        var watched: [StatusSource: Set<String>] = [:]
        if let raw = defaults.dictionary(forKey: watchedComponentsKey) {
            for (key, value) in raw {
                guard let source = StatusSource(rawValue: key), let ids = value as? [String] else { continue }
                watched[source] = Set(ids)
            }
        }
        return StatusPreferences(enabled: enabled, disabledSources: disabled, watchedComponentIDs: watched)
    }

    static func save(_ prefs: StatusPreferences) {
        let defaults = UserDefaults.standard
        defaults.set(prefs.enabled, forKey: enabledKey)
        defaults.set(prefs.disabledSources.map(\.rawValue).sorted(), forKey: disabledSourcesKey)
        var raw: [String: [String]] = [:]
        for (source, ids) in prefs.watchedComponentIDs {
            raw[source.rawValue] = ids.sorted()
        }
        defaults.set(raw, forKey: watchedComponentsKey)
    }
}
