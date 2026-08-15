import Foundation

enum ChatGPTParser {
    /// `/api/auth/session` mints the bearer that `/backend-api/` actually accepts.
    /// A JSON body without `accessToken` is expired — not a later 401 on usage.
    static func parseAccessToken(_ body: Data) -> ChatGPTAuth {
        guard let obj = try? JSONSerialization.jsonObject(with: body) else {
            return .failed(.notJSON)
        }
        guard let root = obj as? [String: Any],
              let token = JSONValue.string(root["accessToken"])
        else {
            return .failed(.expired)
        }
        return .bearer(token)
    }

    static func parseUsage(_ root: [String: Any], accountLabel: String?) -> UsageOutcome {
        let locked = lockState(root)
        var limits: [Limit] = []

        if let rate = JSONValue.object(root["rate_limit"]) {
            limits.append(contentsOf: windows(in: rate, locked: locked, idPrefix: nil))
        }

        // Extra buckets if the provider starts sending them. Walk the shape;
        // do not hardcode tomorrow's names.
        if let extra = JSONValue.object(root["additional_rate_limits"]) {
            for (name, value) in extra.sorted(by: { $0.key < $1.key }) {
                if let obj = JSONValue.object(value) {
                    limits.append(contentsOf: windows(in: obj, locked: locked, idPrefix: name))
                }
            }
        } else if let extra = JSONValue.array(root["additional_rate_limits"]) {
            for (index, obj) in extra.enumerated() {
                limits.append(contentsOf: windows(in: obj, locked: locked, idPrefix: "extra-\(index)"))
            }
        }

        if let review = JSONValue.object(root["code_review_rate_limit"]) {
            limits.append(contentsOf: windows(in: review, locked: locked, idPrefix: "code_review"))
        }

        if limits.isEmpty { return .empty }

        let label = accountLabel ?? JSONValue.string(root["plan_type"])
        return .snapshot(UsageSnapshot(provider: .chatGPT, accountLabel: label, limits: limits))
    }

    /// `allowed` is the honest field. Missing `allowed` stays unknown — `limit_reached`
    /// is not a substitute we invented a mapping for.
    private static func lockState(_ root: [String: Any]) -> LockState {
        let container = JSONValue.object(root["rate_limit"]) ?? root
        guard let allowed = JSONValue.bool(container["allowed"]) else { return .unknown }
        return allowed ? .unlocked : .locked
    }

    private static func windows(in object: [String: Any], locked: LockState, idPrefix: String?) -> [Limit] {
        var result: [Limit] = []
        if let primary = JSONValue.object(object["primary_window"]),
           let limit = window(primary, id: qualify("primary", idPrefix), fallbackLabel: "Window", locked: locked)
        {
            result.append(limit)
        }
        if let secondary = JSONValue.object(object["secondary_window"]),
           let limit = window(secondary, id: qualify("secondary", idPrefix), fallbackLabel: "Second window", locked: locked)
        {
            result.append(limit)
        }
        // A bare window object (used_percent at this level) — additional_rate_limits
        // may send that rather than wrapping it in primary_window.
        if result.isEmpty,
           let limit = window(object, id: qualify("window", idPrefix), fallbackLabel: idPrefix ?? "Window", locked: locked)
        {
            result.append(limit)
        }
        return result
    }

    private static func window(
        _ object: [String: Any],
        id: String,
        fallbackLabel: String,
        locked: LockState
    ) -> Limit? {
        guard let percent = JSONValue.number(object["used_percent"]) else { return nil }
        let seconds = JSONValue.number(object["limit_window_seconds"])
        let label = seconds == nil ? fallbackLabel : WindowLabel.from(seconds: seconds)
        return Limit(
            id: id,
            label: label,
            utilization: percent / 100,
            resetsAt: DateParsing.unixSeconds(object["reset_at"]),
            locked: locked,
            scope: .account
        )
    }

    private static func qualify(_ id: String, _ prefix: String?) -> String {
        prefix.map { "\($0)/\(id)" } ?? id
    }
}
