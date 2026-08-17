import Foundation
import UsageBarCore

/// Reads the four status pages. Parsing lives in `UsageBarCore`; this only
/// fetches and hands the bytes over.
///
/// `URLSession`, not curl: status.x.ai answers a Cloudflare challenge to curl
/// and Python and lets `URLSession` through — the same story as the usage
/// endpoints (AGENTS.md).
struct ServiceStatusClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Short. A status page that is itself struggling must not hold up the
    /// numbers, and "unchecked" is a perfectly good answer.
    private static let timeout: TimeInterval = 8

    /// One read per switched-on source. A source the user switched off is not
    /// requested at all — the switch would otherwise only hide the answer.
    func read(preferences: StatusPreferences) async -> [StatusRead] {
        guard preferences.enabled else { return [] }
        let sources = StatusSource.allCases.filter(preferences.isEnabled)
        guard !sources.isEmpty else { return [] }
        return await withTaskGroup(of: StatusRead.self) { group in
            for source in sources {
                group.addTask { await self.read(source) }
            }
            var reads: [StatusRead] = []
            for await read in group { reads.append(read) }
            return reads
        }
    }

    private func read(_ source: StatusSource) async -> StatusRead {
        switch source {
        case .xAI:
            let feed = await get(source.pageURL.appendingPathComponent("feed.xml"))
            switch feed {
            case .failure(let reason): return .unchecked(source: .xAI, reason: reason)
            case .success(let body): return ServiceStatusParser.xAIFeed(body: body)
            }
        case .claude, .github, .openAI:
            // OpenAI's `summary.json` stops after 25 components and its page
            // has 34 — "Codex API", "CLI" and "VS Code extension" all sit past
            // the cut. `components.json` has the same shape and the whole list.
            let listing = source == .openAI ? "api/v2/components.json" : "api/v2/summary.json"
            let summary = await get(source.pageURL.appendingPathComponent(listing))
            guard case .success(let body) = summary else {
                if case .failure(let reason) = summary { return .unchecked(source: source, reason: reason) }
                return .unchecked(source: source, reason: "No answer")
            }
            let read = ServiceStatusParser.statuspageSummary(source: source, body: body)
            guard source == .openAI else { return read }
            // `components.json` carries no incidents at all, OpenAI's summary
            // has no `incidents` key either, and `incidents/unresolved.json` is
            // a 404 — the open ones have to come from the full list. A failure
            // here leaves the components as they were rather than throwing the
            // whole read away.
            guard case .success(let incidentBody) = await get(source.pageURL.appendingPathComponent("api/v2/incidents.json")),
                  let incidents = ServiceStatusParser.statuspageIncidents(body: incidentBody)
            else { return read }
            return ServiceStatusParser.adding(incidents, to: read)
        }
    }

    private enum Fetch {
        case success(Data)
        case failure(String)
    }

    private func get(_ url: URL) async -> Fetch {
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        request.setValue(AppIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failure("No HTTP response") }
            guard http.statusCode == 200 else { return .failure("Status page answered HTTP \(http.statusCode)") }
            return .success(data)
        } catch {
            return .failure("Status page unreachable")
        }
    }
}
