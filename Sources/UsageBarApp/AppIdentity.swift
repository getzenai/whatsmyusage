/// User-facing name, bundle id, Keychain item. Keep in sync with
/// `Scripts/make-app-bundle.sh` (`APP_NAME`, `BUNDLE_ID`).
enum AppIdentity {
    static let displayName = "WhatsMyUsage"
    static let bundleID = "com.whatsmyusage.app"
    /// Shown verbatim in the macOS Keychain sheet: 'access key "<this>"'.
    static let keychainService = bundleID
    static let website = "https://whatsmyusage.com"
    /// Previous Keychain service. Read once, then rewrite under `keychainService`.
    static let legacyKeychainService = "de.getzenai.ai-usage-bar"
}
