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
            let shares = weeklyShares(root["weekly_scoped_shares"])
            let parsed = limits.enumerated().compactMap { index, entry in
                limit(fromEntry: entry, shareOfWeek: shares[index])
            }
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
                // Claude sends percentages only. `is_active` is not a lock.
                // Inventing `.locked` from 100 % is forbidden — see README.
                locked: .unknown,
                scope: scope,
                severity: severity(entry["severity"])
            )
        }
        if fallback.isEmpty { return .empty }
        return .snapshot(UsageSnapshot(provider: .claude, accountLabel: accountLabel, limits: fallback))
    }

    /// `/api/organizations/{id}/usage?cedar_ember=1`. The vouchers sit under
    /// `cedar_ember`, which the plain `/usage` call sends as `null`. Nil when
    /// that key is not an object or `grants` is not a list — a miss, not zero.
    /// An ineligible plan sends `grants: []`, which is `.none`.
    ///
    /// The count is `resets_left` summed over the grants, the same total
    /// claude.ai shows as "N available". Each grant is dated by its `ends_at`,
    /// once per reset left in it. A grant without a readable `ends_at` or one
    /// already past is skipped, as claude.ai's own parser does.
    ///
    /// claude.ai lists the vouchers by what they reset, and so do we: a grant
    /// whose `clears` holds `seven_day` resets the week ("Weekly" when its
    /// `type` is `weekly`, "Full" when it also clears the 5-hour window, as on
    /// Team). One that leaves the week alone is a model reset, named after the
    /// model-scoped limit in the same response ("Fable"). Measured 2026-11-18
    /// on a Max and a Team org.
    static func parseResetGrants(_ body: Data, now: Date = Date()) -> ResetRead? {
        guard let obj = try? JSONSerialization.jsonObject(with: body),
              let root = obj as? [String: Any],
              let ember = JSONValue.object(root["cedar_ember"]),
              let grants = JSONValue.array(ember["grants"])
        else { return nil }
        let model = scopedModelName(root["limits"])
        var expiring: [Date] = []
        var byName: [(name: String, dates: [Date])] = []
        for grant in grants {
            guard let total = JSONValue.int(grant["resets_total"]), total >= 1,
                  let left = JSONValue.int(grant["resets_left"]), left >= 1,
                  let end = DateParsing.iso8601(grant["ends_at"]), end > now
            else { continue }
            let dates = Array(repeating: end, count: min(left, total))
            expiring.append(contentsOf: dates)
            let name = resetName(grant, model: model)
            if let i = byName.firstIndex(where: { $0.name == name }) {
                byName[i].dates.append(contentsOf: dates)
            } else {
                byName.append((name, dates))
            }
        }
        // `ResetRead.none`, spelled out: a bare `.none` here is `Optional.none`.
        if expiring.isEmpty { return ResetRead.none }
        // One kind of voucher needs no breakdown: the total says it all.
        let groups = byName.count < 2 ? [] : byName
            .map { ResetGroup(name: $0.name, count: $0.dates.count, firstExpiry: $0.dates.min()) }
            .sorted { ($0.firstExpiry ?? .distantFuture) < ($1.firstExpiry ?? .distantFuture) }
        return .available(expiring.count, expiring: expiring.sorted(), groups: groups)
    }

    private static func resetName(_ grant: [String: Any], model: String?) -> String {
        let clears = Set(stringArray(grant["clears"]) ?? [])
        if clears.contains("seven_day") {
            if JSONValue.string(grant["type"]) == "weekly" { return "weekly" }
            return "full"
        }
        return model ?? "model"
    }

    /// The model of the one model-scoped limit, if there is exactly one.
    private static func scopedModelName(_ limits: Any?) -> String? {
        let names = Set((JSONValue.array(limits) ?? []).compactMap { modelName($0["scope"]) })
        return names.count == 1 ? names.first : nil
    }

    static func parseBootstrap(_ root: [String: Any]) -> UsageOutcome {
        let orgs = organizations(in: root)
        if orgs.isEmpty { return .empty }
        // Bootstrap is not a usage reading. The caller uses `organizations(in:)`
        // directly; reaching here with a 200 just means "cookie works".
        return .snapshot(UsageSnapshot(provider: .claude, limits: [
            Limit(
                id: "bootstrap",
                label: "signed in",
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

    /// `weekly_scoped_shares[]`: `limit_index` points into `limits[]`,
    /// `allowance_percent_of_weekly` is the share of the week that model may
    /// use. claude.ai prints it as "Up to 50% of your weekly limit".
    private static func weeklyShares(_ value: Any?) -> [Int: Double] {
        var shares: [Int: Double] = [:]
        for entry in JSONValue.array(value) ?? [] {
            guard let index = JSONValue.int(entry["limit_index"]),
                  let percent = JSONValue.number(entry["allowance_percent_of_weekly"])
            else { continue }
            shares[index] = percent / 100
        }
        return shares
    }

    private static func limit(fromEntry entry: [String: Any], shareOfWeek: Double? = nil) -> Limit? {
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
            // Claude sends percentages only. `is_active` is not a lock.
            locked: .unknown,
            scope: model == nil ? .account : .model,
            severity: severity(entry["severity"]),
            shareOfWeek: model == nil ? nil : shareOfWeek
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
        case "session", "five_hour": base = "5 hours"
        case "weekly_all", "seven_day", "weekly": base = "Week"
        case "weekly_scoped": base = "Week"
        case "seven_day_sonnet": return "Week · Sonnet"
        case "seven_day_opus": return "Week · Opus"
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
