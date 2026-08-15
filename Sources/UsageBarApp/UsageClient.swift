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

    func refresh(using creds: ExtractedCredentials) async -> [Provider: [UsageOutcome]] {
        await withTaskGroup(of: (Provider, [UsageOutcome]).self) { group in
            if let claude = creds.claude {
                group.addTask { (.claude, await self.fetchClaude(claude)) }
            }
            if let gpt = creds.chatGPT {
                group.addTask { (.chatGPT, [await self.fetchChatGPT(gpt)]) }
            }
            if let grok = creds.grok {
                group.addTask { (.grok, await self.fetchGrok(grok)) }
            }
            var result: [Provider: [UsageOutcome]] = [:]
            for await (provider, outcomes) in group {
                result[provider] = outcomes
            }
            return result
        }
    }

    // MARK: - Claude

    private func fetchClaude(_ creds: ClaudeCredentials) async -> [UsageOutcome] {
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
        if case .expired = bootstrapOutcome { return [.expired] }
        if case .notJSON = bootstrapOutcome { return [.notJSON] }
        if bootstrap.status != 200 { return [bootstrapOutcome] }

        let orgs = UsageParser.claudeOrganizations(from: bootstrap.body)
        let trackable = orgs.filter(\.isChatCapable)
        if trackable.isEmpty {
            // Cookie works, but no chat org. Surface the API-console 403s rather
            // than pretending there is nothing.
            return orgs.isEmpty ? [.empty] : [.notTrackable(message: "keine Chat-Organisation")]
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
                let prefixed = snap.limits.map { $0.prefixed(id: org.id, label: org.name) }
                outcomes.append(.snapshot(UsageSnapshot(
                    provider: .claude,
                    accountLabel: org.name,
                    limits: prefixed
                )))
            } else {
                outcomes.append(outcome)
            }
        }
        return outcomes
    }

    // MARK: - ChatGPT

    private func fetchChatGPT(_ creds: ChatGPTCredentials) async -> UsageOutcome {
        let session = await get(
            url: URL(string: "https://chatgpt.com/api/auth/session")!,
            cookie: creds.cookieHeader
        )
        switch UsageParser.chatGPTAccessToken(statusCode: session.status, body: session.body) {
        case .failed(let outcome):
            return outcome
        case .bearer(let token):
            let response = await get(
                url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
                cookie: creds.cookieHeader,
                authorization: "Bearer \(token)"
            )
            return UsageParser.parseUsage(
                provider: .chatGPT,
                statusCode: response.status,
                body: response.body
            )
        }
    }

    // MARK: - Grok

    private func fetchGrok(_ creds: GrokCredentials) async -> [UsageOutcome] {
        var outcomes: [UsageOutcome] = []
        for model in grokModels {
            let body = (try? JSONSerialization.data(withJSONObject: ["modelName": model])) ?? Data()
            let response = await post(
                url: URL(string: "https://grok.com/rest/rate-limits")!,
                cookie: creds.cookieHeader,
                json: body
            )
            outcomes.append(UsageParser.parseUsage(
                provider: .grok,
                statusCode: response.status,
                body: response.body,
                context: ParseContext(grokModel: model)
            ))
        }
        // Weekly is a separate call. If it fails, keep the 2-hour windows —
        // do not turn the whole provider into "!".
        let weekly = await postGrpcWeb(
            url: URL(string: "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig")!,
            cookie: creds.cookieHeader
        )
        if weekly.status == 200, let limit = UsageParser.parseGrokWeekly(body: weekly.body) {
            outcomes.append(.snapshot(UsageSnapshot(provider: .grok, limits: [limit])))
        }
        return outcomes
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
