/// User-facing name, bundle id, Keychain item. Keep in sync with
/// `Scripts/make-app-bundle.sh` (`APP_NAME`, `BUNDLE_ID`).
enum AppIdentity {
    static let displayName = "WhatsMyUsage"
    static let bundleID = "com.whatsmyusage.app"
    /// Shown verbatim in the macOS Keychain sheet as the item name.
    /// The product domain, not the bundle id — people read this as the site.
    static let keychainService = "whatsmyusage.com"
    static let websiteHost = "whatsmyusage.com"
    static let website = "https://whatsmyusage.com"
    /// UserDefaults suite of the first shipping bundle. Not a Keychain name.
    static let legacyDefaultsSuite = "de.getzenai.ai-usage-bar"
    /// Previous Keychain service names, newest first. Read once, then rewrite.
    static let legacyKeychainServices = [
        "com.whatsmyusage.app",
        "de.getzenai.ai-usage-bar",
    ]
}
