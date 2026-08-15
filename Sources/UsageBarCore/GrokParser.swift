import Foundation

enum GrokParser {
    static func parseUsage(_ root: [String: Any], model: String, accountLabel: String?) -> UsageOutcome {
        var limits: [Limit] = []

        if let top = window(root, id: model, label: label(for: root, model: model)) {
            limits.append(top)
        }

        // Nested objects that look like a rate window (remaining + total) become
        // their own limits. Names are taken from the JSON keys, not a allow-list.
        for (key, value) in root.sorted(by: { $0.key < $1.key }) {
            guard let obj = JSONValue.object(value) else { continue }
            guard looksLikeWindow(obj) else { continue }
            if let limit = window(obj, id: "\(model)/\(key)", label: "\(label(for: obj, model: model)) · \(key)") {
                limits.append(limit)
            }
        }

        if limits.isEmpty { return .empty }
        // Fast / Expert are windows on the same Grok account — never their own card.
        return .snapshot(UsageSnapshot(
            provider: .grok,
            trackingID: "grok",
            accountLabel: accountLabel,
            limits: limits
        ))
    }

    /// `GetGrokCreditsConfig` (grpc-web). Only a weekly period (`1.8.1 == 2`)
    /// becomes a limit; any other period type is dropped, not remapped.
    ///
    /// Proto3 omits a numeric field at default 0, so a missing `1.1` after a
    /// weekly period is 0 %, not "no answer". That case is unread against a
    /// live 0 % account — it follows the wire rule.
    static func parseWeekly(_ body: Data) -> Limit? {
        guard let message = GrpcWeb.dataMessage(from: body),
              let root = Proto.decode(message),
              let config = Proto.message(root, 1),
              let period = Proto.message(config, 8),
              Proto.varint(period, 1) == 2
        else { return nil }

        let percent = Proto.float(config, 1) ?? 0
        guard percent.isFinite else { return nil }

        var resetsAt: Date?
        if let end = Proto.message(period, 3), let seconds = Proto.varint(end, 1) {
            let nanos = Proto.varint(end, 2) ?? 0
            resetsAt = Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
        }

        return Limit(
            id: "weekly",
            label: "Week",
            utilization: Double(percent) / 100,
            resetsAt: resetsAt,
            locked: Double(percent) >= 100 ? .locked : .unknown,
            scope: .account
        )
    }

    private static func looksLikeWindow(_ obj: [String: Any]) -> Bool {
        obj["remainingQueries"] != nil && obj["totalQueries"] != nil
    }

    private static func window(_ obj: [String: Any], id: String, label: String) -> Limit? {
        guard let remaining = JSONValue.number(obj["remainingQueries"]),
              let total = JSONValue.number(obj["totalQueries"]),
              total > 0
        else { return nil }

        let utilization = 1 - (remaining / total)
        let locked: LockState = remaining == 0 ? .locked : .unlocked
        return Limit(
            id: id,
            label: label,
            utilization: utilization,
            resetsAt: nil,
            locked: locked,
            scope: .account
        )
    }

    private static func label(for obj: [String: Any], model: String) -> String {
        let window = WindowLabel.from(seconds: JSONValue.number(obj["windowSizeSeconds"]))
        return "\(displayModel(model)) · \(window)"
    }

    /// "fast" is a model name, not a second Grok account.
    private static func displayModel(_ model: String) -> String {
        guard let first = model.first else { return model }
        return String(first).uppercased() + model.dropFirst()
    }
}
