import Foundation

/// Marketing version plus the git short hash written into the bundle by
/// `Scripts/make-app-bundle.sh`. A hardcoded 0.1.0 on every build made it
/// impossible to tell which commit was running.
enum AppVersion {
    static var label: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if build.isEmpty || build == short { return short }
        return "\(short) · \(build)"
    }
}
