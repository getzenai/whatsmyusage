import Foundation
import UsageBarCore

/// Talks to the three providers through `URLSession`. Do not replace this with
/// curl or URLSession-from-Python: Cloudflare challenges those. Measured 2026-08-15.
struct UsageClient {
    var grokModels: [String]
    private let session: URLSession

    init(grokModels: [String] = ["fast"], session: URLSession = .shared) {
        self.grokModels = grokModels
        self.session = session
    }

    func refresh(using store: CredentialStore) async -> RefreshResult {
        await withTaskGroup(of: AccountFetch.self) { group in
            for account in store.accounts {
                if let claude = account.claude {
                    group.addTask { await self.fetchClaude(claude, accountID: account.id) }
                }
                if let gpt = account.chatGPT {
                    group.addTask { await self.fetchChatGPT(gpt, accountID: account.id) }
                }
                if let grok = account.grok {
                    group.addTask { await self.fetchGrok(grok, accountID: account.id) }
                }
            }
            var byProvider: [Provider: [UsageOutcome]] = [:]
            var orgIDs: [String: Set<String>] = [:]
            for await fetch in group {
                byProvider[fetch.provider, default: []].append(contentsOf: fetch.outcomes)
                if let ids = fetch.claudeOrgIDs {
                    orgIDs[fetch.accountID] = ids
                }
            }
            return RefreshResult(byProvider: byProvider, claudeOrgIDsByAccountID: orgIDs)
        }
    }

    struct RefreshResult: Sendable {
        var byProvider: [Provider: [UsageOutcome]]
        var claudeOrgIDsByAccountID: [String: Set<String>]
    }

    private struct AccountFetch: Sendable {
        var provider: Provider
        var accountID: String
        var outcomes: [UsageOutcome]
        var claudeOrgIDs: Set<String>?
    }

    // MARK: - Claude

    private func fetchClaude(_ creds: ClaudeCredentials, accountID: String) async -> AccountFetch {
        let bootstrap = await get(
            url: URL(string: "https://claude.ai/api/bootstrap")!,
            cookie: creds.cookieHeader
        )
        let bootstrapOutcome = UsageParser.parseUsage(
            provider: .claude,
            statusCode: bootstrap.status,
            body: bootstrap.body,
            endpoint: .bootstrap
        )
        if case .expired = bootstrapOutcome {
            return AccountFetch(
                provider: .claude,
                accountID: accountID,
                outcomes: [retag(bootstrapOutcome, provider: .claude, trackingID: claudeTrackingID(creds, accountID: accountID))],
                claudeOrgIDs: nil
            )
        }
        if case .notJSON = bootstrapOutcome {
            return AccountFetch(
                provider: .claude,
                accountID: accountID,
                outcomes: [retag(bootstrapOutcome, provider: .claude, trackingID: claudeTrackingID(creds, accountID: accountID))],
                claudeOrgIDs: nil
            )
        }
        if bootstrap.status != 200 {
            return AccountFetch(
                provider: .claude,
                accountID: accountID,
                outcomes: [retag(bootstrapOutcome, provider: .claude, trackingID: claudeTrackingID(creds, accountID: accountID))],
                claudeOrgIDs: nil
            )
        }

        let orgs = UsageParser.claudeOrganizations(from: bootstrap.body)
        let trackable = orgs.filter(\.isChatCapable)
        if trackable.isEmpty {
            // Cookie works, but no chat org. Surface the API-console 403s rather
            // than pretending there is nothing.
            let outcome: UsageOutcome = orgs.isEmpty ? .empty : .notTrackable(message: "no chat organization")
            return AccountFetch(
                provider: .claude,
                accountID: accountID,
                outcomes: [retag(outcome, provider: .claude, trackingID: claudeTrackingID(creds, accountID: accountID))],
                claudeOrgIDs: Set(orgs.map(\.id))
            )
        }

        var outcomes: [UsageOutcome] = []
        for org in trackable {
            let encoded = org.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? org.id
            let url = URL(string: "https://claude.ai/api/organizations/\(encoded)/usage")!
            let response = await get(url: url, cookie: creds.cookieHeader)
            let outcome = UsageParser.parseUsage(
                provider: .claude,
                statusCode: response.status,
                body: response.body,
                endpoint: .usage,
                context: ParseContext(accountLabel: org.name)
            )
            if case .snapshot(let snap) = outcome {
                let unique = snap.limits.map { $0.withIDPrefix(org.id) }
                outcomes.append(.snapshot(UsageSnapshot(
                    provider: .claude,
                    trackingID: "claude:\(org.id)",
                    accountLabel: org.name,
                    limits: unique
                )))
            } else {
                // Keep the org visible. Dropping this row is the same class of
                // bug as a silent 0 %: the healthy sibling would hide the failure.
                outcomes.append(.snapshot(UsageSnapshot(
                    provider: .claude,
                    trackingID: "claude:\(org.id)",
                    accountLabel: org.name,
                    limits: [],
                    diagnostic: Self.diagnostic(for: outcome)
                )))
            }
        }
        return AccountFetch(
            provider: .claude,
            accountID: accountID,
            outcomes: outcomes,
            claudeOrgIDs: Set(trackable.map(\.id))
        )
    }

    // MARK: - ChatGPT

    private func fetchChatGPT(_ creds: ChatGPTCredentials, accountID: String) async -> AccountFetch {
        let trackingID = "chatgpt:\(accountID)"
        let session = await get(
            url: URL(string: "https://chatgpt.com/api/auth/session")!,
            cookie: creds.cookieHeader
        )
        let outcome: UsageOutcome
        switch UsageParser.chatGPTAccessToken(statusCode: session.status, body: session.body) {
        case .failed(let failed):
            outcome = failed
        case .bearer(let token):
            let response = await get(
                url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                cookie: creds.cookieHeader,
                authorization: "Bearer \(token)"
            )
            outcome = UsageParser.parseUsage(
                provider: .chatGPT,
                statusCode: response.status,
                body: response.body
            )
        }
        return AccountFetch(
            provider: .chatGPT,
            accountID: accountID,
            outcomes: [retag(outcome, provider: .chatGPT, trackingID: trackingID)],
            claudeOrgIDs: nil
        )
    }

    // MARK: - Grok

    private func fetchGrok(_ creds: GrokCredentials, accountID: String) async -> AccountFetch {
        let trackingID = "grok:\(accountID)"
        let outcomes = await fetchGrokOutcomes(creds, trackingID: trackingID)
        return AccountFetch(provider: .grok, accountID: accountID, outcomes: outcomes, claudeOrgIDs: nil)
    }

    private func fetchGrokOutcomes(_ creds: GrokCredentials, trackingID: String) async -> [UsageOutcome] {
        var limits: [Limit] = []
        var errors: [UsageOutcome] = []
        for model in grokModels {
            let body = (try? JSONSerialization.data(withJSONObject: ["modelName": model])) ?? Data()
            let response = await post(
                url: URL(string: "https://grok.com/rest/rate-limits")!,
                cookie: creds.cookieHeader,
                json: body
            )
            let outcome = UsageParser.parseUsage(
                provider: .grok,
                statusCode: response.status,
                body: response.body,
                context: ParseContext(grokModel: model)
            )
            if case .snapshot(let snap) = outcome {
                limits.append(contentsOf: snap.limits)
            } else {
                errors.append(outcome)
            }
        }
        // Weekly is a separate call. If it fails, keep the 2-hour windows —
        // do not turn the whole provider into "!".
        let weekly = await postGrpcWeb(
            url: URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!,
            cookie: creds.cookieHeader
        )
        if weekly.status == 200, let limit = UsageParser.parseGrokWeekly(body: weekly.body) {
            limits.append(limit)
        }
        var outcomes: [UsageOutcome] = []
        if !limits.isEmpty {
            outcomes.append(.snapshot(UsageSnapshot(
                provider: .grok,
                trackingID: trackingID,
                limits: limits
            )))
        } else if let error = errors.first {
            // Same tracking id as a live card. A naked `.httpError` would become
            // the card id `grok` and `owns("grok")` used to match every Grok login.
            outcomes.append(retag(error, provider: .grok, trackingID: trackingID))
        }
        return outcomes
    }

    private func claudeTrackingID(_ creds: ClaudeCredentials, accountID: String) -> String {
        if let org = creds.lastActiveOrg, !org.isEmpty { return "claude:\(org)" }
        return "claude:account:\(accountID)"
    }

    private func retag(
        _ outcome: UsageOutcome,
        provider: Provider,
        trackingID: String,
        accountLabel: String? = nil
    ) -> UsageOutcome {
        if case .snapshot(let snap) = outcome {
            return .snapshot(UsageSnapshot(
                provider: provider,
                trackingID: trackingID,
                accountLabel: accountLabel ?? snap.accountLabel,
                limits: snap.limits,
                diagnostic: snap.diagnostic
            ))
        }
        return .snapshot(UsageSnapshot(
            provider: provider,
            trackingID: trackingID,
            accountLabel: accountLabel,
            limits: [],
            diagnostic: Self.diagnostic(for: outcome)
        ))
    }

    // MARK: - Transport

    private struct HTTPResponse {
        var status: Int
        var body: Data
    }

    private func get(url: URL, cookie: String, authorization: String? = nil) async -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        return await send(request)
    }

    private func post(url: URL, cookie: String, json: Data) async -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = json
        return await send(request)
    }

    private func postGrpcWeb(url: URL, cookie: String) async -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Grpc-Web")
        // Empty protobuf message: data flag + 4-byte zero length. Measured.
        request.httpBody = Data([0x00, 0x00, 0x00, 0x00, 0x00])
        return await send(request)
    }

    private static func diagnostic(for outcome: UsageOutcome) -> String {
        switch outcome {
        case .expired:
            return "Sign-in expired"
        case .notTrackable(let message):
            return "Not trackable: \(message)"
        case .httpError(let status):
            return status < 0 ? "Network error" : "HTTP \(status)"
        case .notJSON:
            return "Response was not JSON"
        case .empty:
            return "No limits in the response"
        case .snapshot:
            return "Unknown error"
        }
    }

    private func send(_ request: URLRequest) async -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            return HTTPResponse(status: status, body: data)
        } catch {
            // Network failures are not auth failures. Surface as an HTTP-shaped error
            // so the bar can show "!" without greying a healthy cookie.
            return HTTPResponse(status: -1, body: Data())
        }
    }
}
