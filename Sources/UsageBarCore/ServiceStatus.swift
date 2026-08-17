import Foundation

/// A status page we read. Three of them belong to a provider we already track;
/// GitHub belongs to no account and is shown on its own line.
public enum StatusSource: String, Sendable, CaseIterable, Codable {
    case claude
    case openAI = "openai"
    case xAI = "xai"
    case github

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .openAI: "OpenAI"
        case .xAI: "xAI"
        case .github: "GitHub"
        }
    }

    /// The account a disruption here belongs to, or nil when it belongs to none.
    public var provider: Provider? {
        switch self {
        case .claude: .claude
        case .openAI: .chatGPT
        case .xAI: .grok
        case .github: nil
        }
    }

    public var pageURL: URL {
        switch self {
        case .claude: URL(string: "https://status.claude.com")!
        case .openAI: URL(string: "https://status.openai.com")!
        case .xAI: URL(string: "https://status.x.ai")!
        case .github: URL(string: "https://www.githubstatus.com")!
        }
    }
}

/// How badly a component is doing, in the vocabulary the pages use.
/// `unknown` is a word we have not seen before — it counts as trouble, because
/// a status page does not invent a new word to say "fine".
public enum ComponentHealth: String, Sendable, Equatable, Codable {
    case operational
    case degraded
    case partialOutage
    case majorOutage
    case maintenance
    case unknown

    public var isTrouble: Bool { self != .operational && self != .maintenance }

    public var label: String {
        switch self {
        case .operational: "operational"
        case .degraded: "degraded"
        case .partialOutage: "partial outage"
        case .majorOutage: "major outage"
        case .maintenance: "maintenance"
        case .unknown: "unknown state"
        }
    }
}

/// One service on a status page.
public struct StatusComponent: Equatable, Sendable, Identifiable, Codable {
    public let id: String
    public let name: String
    public let health: ComponentHealth

    public init(id: String, name: String, health: ComponentHealth) {
        self.id = id
        self.name = name
        self.health = health
    }
}

/// One open incident. Only unresolved ones ever become a `StatusIncident` —
/// the history is not our business.
public struct StatusIncident: Equatable, Sendable, Identifiable, Codable {
    public let id: String
    public let title: String
    /// The page's own word for its stage: investigating, identified, monitoring…
    /// Carried, never interpreted: only "resolved" has a meaning we act on, and
    /// that one never reaches here.
    public let stage: String?
    public let startedAt: Date?
    public let url: URL?
    /// Component ids the page says are affected. Empty means the page did not
    /// say — the incident then counts for the whole source. OpenAI never says.
    public let componentIDs: [String]
    public let componentNames: [String]

    public init(
        id: String,
        title: String,
        stage: String? = nil,
        startedAt: Date? = nil,
        url: URL? = nil,
        componentIDs: [String] = [],
        componentNames: [String] = []
    ) {
        self.id = id
        self.title = title
        self.stage = stage
        self.startedAt = startedAt
        self.url = url
        self.componentIDs = componentIDs
        self.componentNames = componentNames
    }
}

/// What one page said when we asked it.
public struct StatusReport: Equatable, Sendable {
    public let source: StatusSource
    public let components: [StatusComponent]
    public let incidents: [StatusIncident]

    public init(source: StatusSource, components: [StatusComponent] = [], incidents: [StatusIncident] = []) {
        self.source = source
        self.components = components
        self.incidents = incidents
    }
}

/// The reading, including the case where there was none.
///
/// `unchecked` exists so silence never renders as health. A page that times out,
/// changes its shape, or answers 503 tells us nothing about the provider — and
/// "no incidents" would be a claim we did not earn.
public enum StatusRead: Equatable, Sendable {
    case report(StatusReport)
    case unchecked(source: StatusSource, reason: String)

    public var source: StatusSource {
        switch self {
        case .report(let report): report.source
        case .unchecked(let source, _): source
        }
    }
}

/// Which pages are read and which of their services count.
public struct StatusPreferences: Equatable, Sendable {
    /// The master switch. Off means no line, no banner, no dot — and no request.
    public var enabled: Bool
    /// Sources the user switched off individually.
    public var disabledSources: Set<StatusSource>
    /// Component ids the user chose per source. A source missing here uses the
    /// built-in default; an empty set means the user unticked everything, which
    /// is the same as switching the source off.
    public var watchedComponentIDs: [StatusSource: Set<String>]

    public init(
        enabled: Bool = true,
        disabledSources: Set<StatusSource> = [],
        watchedComponentIDs: [StatusSource: Set<String>] = [:]
    ) {
        self.enabled = enabled
        self.disabledSources = disabledSources
        self.watchedComponentIDs = watchedComponentIDs
    }

    public func isEnabled(_ source: StatusSource) -> Bool {
        enabled && !disabledSources.contains(source)
    }

    public mutating func setEnabled(_ on: Bool, for source: StatusSource) {
        if on { disabledSources.remove(source) } else { disabledSources.insert(source) }
    }

    /// The ids that count for this source, resolved against what the page
    /// actually lists today. Nil means "everything counts" — the user has not
    /// narrowed it and we have no default to narrow it with.
    public func watched(_ source: StatusSource, among components: [StatusComponent]) -> Set<String>? {
        if let chosen = watchedComponentIDs[source] { return chosen }
        guard let names = StatusDefaults.componentNames[source] else { return nil }
        let matched = components.filter { names.contains($0.name) }.map(\.id)
        // A page that renamed every default component must not silently watch
        // nothing. Falling back to everything is the loud direction.
        return matched.isEmpty ? nil : Set(matched)
    }

    public mutating func toggleComponent(
        _ id: String,
        for source: StatusSource,
        among components: [StatusComponent]
    ) {
        var current = watched(source, among: components) ?? Set(components.map(\.id))
        if current.contains(id) { current.remove(id) } else { current.insert(id) }
        watchedComponentIDs[source] = current
    }
}

/// The components each page starts out watching. Names, not ids: an id is
/// opaque and a page may reissue it, while these names are what the user reads
/// on the page itself. Measured 2026-08-17.
public enum StatusDefaults {
    public static let componentNames: [StatusSource: Set<String>] = [
        .claude: ["claude.ai", "Claude Code", "Claude API (api.anthropic.com)"],
        .github: ["Actions", "API Requests", "Pull Requests", "Issues"],
        .xAI: [XAIServices.grokWeb, XAIServices.singleSignOn],
        // OpenAI's page lists 34 services, most of them things we never touch —
        // Sora, Ads Manager, FedRAMP. These are the ones a coding session runs
        // through, plus the sign-in without which none of them work. Two
        // components are both named "Login" and matching by name watches both,
        // which is the loud direction.
        .openAI: [
            "Codex Web",
            "Codex API",
            "Codex in ChatGPT Desktop",
            "CLI",
            "VS Code extension",
            "Responses",
            "Conversations",
            "Login",
        ],
    ]

    /// Every source narrows by default. This stays as the one place that says
    /// whether a source has one, so the Settings note can be honest about a
    /// source that does not.
    public static func hasDefault(_ source: StatusSource) -> Bool {
        componentNames[source] != nil
    }
}

/// xAI's services, keyed by the slug that appears in its feed links. The feed
/// is the only machine-readable thing the page offers and it carries slugs, not
/// names — so the names live here. Measured 2026-08-17.
public enum XAIServices {
    public static let grokWeb = "Grok (Web)"
    public static let singleSignOn = "Single Sign-On"

    public static let namesBySlug: [String: String] = [
        "grok-com": grokWeb,
        "ios-app": "Grok (iOS)",
        "android-app": "Grok (Android)",
        "grok-in-x": "Grok in X",
        "single-sign-on": singleSignOn,
        "api-us-east-1": "API (us-east-1.api.x.ai)",
        "api-us-west-2": "API (us-west-2.api.x.ai)",
        "api-eu-west-1": "API (eu-west-1.api.x.ai)",
        "api-console": "API Console",
        "docs": "Docs",
        "xai-website": "xAI Website",
    ]

    /// The list Settings offers. A slug the feed mentions but this table does
    /// not know is *not* dropped — see `ServiceStatusParser.xAIFeed`.
    public static var components: [StatusComponent] {
        namesBySlug
            .map { StatusComponent(id: $0.key, name: $0.value, health: .operational) }
            .sorted { $0.name < $1.name }
    }
}
