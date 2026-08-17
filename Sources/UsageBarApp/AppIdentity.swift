import Foundation

/// User-facing name, bundle id, Keychain item. Keep in sync with
/// `Scripts/make-app-bundle.sh` (`APP_NAME`, `BUNDLE_ID`).
enum AppIdentity {
    /// Keep in sync with `UsageLog.defaultAppName` — that is how the CLI finds the log.
    static let displayName = "WhatsMyUsage"
    static let bundleID = "com.whatsmyusage.app"
    /// Shown verbatim in the macOS Keychain sheet: 'access key "<this>"'.
    /// The product domain, not the bundle id — people read this as the site.
    static let keychainService = "whatsmyusage.com"
    static let websiteHost = "whatsmyusage.com"
    static let website = "https://whatsmyusage.com"
    /// Sent to the status pages so an operator can see who is polling them and
    /// where to complain. The usage endpoints keep the browser's own header —
    /// this one only goes to public status pages.
    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "\(displayName)/\(version) (+\(website))"
    }
    /// UserDefaults suite of the first shipping bundle. Not a Keychain name.
    static let legacyDefaultsSuite = "de.getzenai.ai-usage-bar"
    /// Previous Keychain service names, newest first. Read once, then rewrite.
    static let legacyKeychainServices = [
        "com.whatsmyusage.app",
        "de.getzenai.ai-usage-bar",
    ]
}
