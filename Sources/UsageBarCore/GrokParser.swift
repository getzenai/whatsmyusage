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

    /// `GetRemainingResets` (grpc-web). Field numbers from `consumer_ui.proto`
    /// in the Grok client chunk (`messageDesc(b, 40)`), 2026-08-16 — **not**
    /// checked against a non-empty live response. `10` repeated `tokens`;
    /// each `10` token_id, `20` validity_start, `30` validity_end.
    ///
    /// An empty data frame is a real answer (no tokens), not a miss. A
    /// missing data frame or a bad trailer is a miss — return nil, never 0.
    /// Count a token only when `token_id` is non-empty and `validity_end` is
    /// in the future. If `validity_start` is present and still in the future,
    /// skip it (a voucher that is not valid yet must not count today). A
    /// missing start field is treated as already started — the bundle's
    /// handling of that omission was not re-read from the chunk.
    static func parseRemainingResets(_ body: Data, now: Date = Date()) -> ResetRead? {
        guard let message = GrpcWeb.dataMessage(from: body),
              let root = Proto.decode(message)
        else { return nil }

        var count = 0
        for token in Proto.messages(root, 10) {
            guard let id = Proto.string(token, 10), !id.isEmpty else { continue }
            if let start = timestamp(token, 20), start > now { continue }
            guard let end = timestamp(token, 30), end > now else { continue }
            count += 1
        }
        // `ResetRead.none`, spelled out: a bare `.none` in a `ResetRead?` context
        // resolves to `Optional.none` — nil — and nil means "we did not read this",
        // which keeps the stale count on screen. Zero vouchers is a reading.
        return count >= 1 ? .available(count) : ResetRead.none
    }

    private static func timestamp(_ fields: [Proto.Field], _ number: UInt64) -> Date? {
        guard let message = Proto.message(fields, number),
              let seconds = Proto.varint(message, 1)
        else { return nil }
        let nanos = Proto.varint(message, 2) ?? 0
        return Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
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
