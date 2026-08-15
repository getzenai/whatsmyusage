import Foundation

public struct ClaudeOrg: Equatable, Sendable {
    public let id: String
    public let name: String
    public let capabilities: [String]

    public init(id: String, name: String, capabilities: [String]) {
        self.id = id
        self.name = name
        self.capabilities = capabilities
    }

    public var isChatCapable: Bool { capabilities.contains("chat") }
}

enum ClaudeParser {
    /// Top-level keys used only when `limits[]` is missing or empty. Kept short on
    /// purpose: the live response has a dozen other always-null codenames that will
    /// have different names tomorrow.
    private static let fallbackKeys: [(key: String, scope: LimitScope)] = [
        ("five_hour", .account),
        ("seven_day", .account),
        ("seven_day_sonnet", .model),
        ("seven_day_opus", .model),
    ]

    static func apiError(in root: [String: Any]) -> String? {
        guard root["type"] as? String == "error",
              let error = JSONValue.object(root["error"])
        else { return nil }
        let type = JSONValue.string(error["type"]) ?? "error"
        let message = JSONValue.string(error["message"]) ?? type
        return message
    }

    static func parseUsage(_ root: [String: Any], accountLabel: String?) -> UsageOutcome {
        if let limits = JSONValue.array(root["limits"]), !limits.isEmpty {
            let parsed = limits.compactMap(limit(fromEntry:))
            if !parsed.isEmpty {
                return .snapshot(UsageSnapshot(provider: .claude, accountLabel: accountLabel, limits: parsed))
            }
        }

        let fallback = fallbackKeys.compactMap { key, scope -> Limit? in
            guard let entry = JSONValue.object(root[key]) else { return nil }
            guard let percent = JSONValue.number(entry["utilization"]) ?? JSONValue.number(entry["percent"])
            else { return nil }
            return Limit(
                id: key,
                label: displayName(forKind: key, model: nil),
                utilization: percent / 100,
                resetsAt: DateParsing.iso8601(entry["resets_at"]),
                locked: .unknown,
                scope: scope,
                severity: severity(entry["severity"])
            )
        }
        if fallback.isEmpty { return .empty }
        return .snapshot(UsageSnapshot(provider: .claude, accountLabel: accountLabel, limits: fallback))
    }

    static func parseBootstrap(_ root: [String: Any]) -> UsageOutcome {
        let orgs = organizations(in: root)
        if orgs.isEmpty { return .empty }
        // Bootstrap is not a usage reading. The caller uses `organizations(in:)`
        // directly; reaching here with a 200 just means "cookie works".
        return .snapshot(UsageSnapshot(provider: .claude, limits: [
            Limit(
                id: "bootstrap",
                label: "angemeldet",
                utilization: 0,
                resetsAt: nil,
                locked: .unknown,
                scope: .account
            ),
        ]))
    }

    /// Memberships under `account.memberships[]`. Shape is walked, not hardcoded:
    /// uuid/name/capabilities have been seen on both the membership and its
    /// `organization` object.
    static func organizations(in root: [String: Any]) -> [ClaudeOrg] {
        let account = JSONValue.object(root["account"]) ?? root
        let raw = (account["memberships"] as? [Any]) ?? []
        return raw.compactMap { item -> ClaudeOrg? in
            guard let membership = item as? [String: Any] else { return nil }
            let org = JSONValue.object(membership["organization"]) ?? membership
            let id = JSONValue.string(org["uuid"])
                ?? JSONValue.string(org["id"])
                ?? JSONValue.string(membership["organization_uuid"])
                ?? JSONValue.string(membership["uuid"])
            guard let id else { return nil }
            let name = JSONValue.string(org["name"])
                ?? JSONValue.string(membership["name"])
                ?? id
            let capabilities = stringArray(org["capabilities"])
                ?? stringArray(membership["capabilities"])
                ?? []
            return ClaudeOrg(id: id, name: name, capabilities: capabilities)
        }
    }

    static func parseBootstrapData(_ data: Data) -> [ClaudeOrg] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        return organizations(in: root)
    }

    private static func limit(fromEntry entry: [String: Any]) -> Limit? {
        guard let percent = JSONValue.number(entry["percent"]) else { return nil }
        // Unknown `kind` values pass through. New limits must show up without a release.
        let kindKey = JSONValue.string(entry["kind"])
            ?? JSONValue.string(entry["group"])
            ?? "unknown"
        let model = modelName(entry["scope"])
        return Limit(
            id: model.map { "\(kindKey):\($0)" } ?? kindKey,
            label: displayName(forKind: kindKey, model: model),
            utilization: percent / 100,
            resetsAt: DateParsing.iso8601(entry["resets_at"]),
            locked: .unknown,
            scope: model == nil ? .account : .model,
            severity: severity(entry["severity"])
        )
    }

    private static func modelName(_ scope: Any?) -> String? {
        guard let scope = JSONValue.object(scope),
              let model = JSONValue.object(scope["model"]),
              let name = JSONValue.string(model["display_name"])
        else { return nil }
        return name
    }

    private static func displayName(forKind kind: String, model: String?) -> String {
        let base: String
        switch kind {
        case "session", "five_hour": base = "5 Stunden"
        case "weekly_all", "seven_day", "weekly": base = "Woche"
        case "weekly_scoped": base = "Woche"
        case "seven_day_sonnet": return "Woche · Sonnet"
        case "seven_day_opus": return "Woche · Opus"
        default: base = kind.replacingOccurrences(of: "_", with: " ")
        }
        return model.map { "\(base) · \($0)" } ?? base
    }

    private static func severity(_ value: Any?) -> LimitSeverity {
        guard let raw = JSONValue.string(value) else { return .unknown }
        return LimitSeverity(rawValue: raw) ?? .unknown
    }

    private static func stringArray(_ value: Any?) -> [String]? {
        (value as? [Any])?.compactMap { JSONValue.string($0) }
    }
}
