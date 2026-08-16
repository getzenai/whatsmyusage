import Foundation

public enum Endpoint: String, Sendable, Equatable {
    case bootstrap
    case usage
}

/// Result of turning an HTTP status plus a body into the common model.
///
/// Expected API states are values, not thrown errors: a 403 on one Claude org is
/// something the app must keep working through, not an exception path.
public enum UsageOutcome: Equatable, Sendable {
    case snapshot(UsageSnapshot)
    /// 401, or 403 on Claude `/api/bootstrap`. The cookie is dead.
    case expired
    /// 403 on a single org's `/usage` (`permission_error`). Cookie is fine.
    case notTrackable(message: String)
    case httpError(status: Int)
    case notJSON
    /// Valid JSON, but nothing that is a limit. Must not look like "everything is free".
    case empty
}

/// Result of reading ChatGPT `/api/auth/session`.
public enum ChatGPTAuth: Equatable, Sendable {
    case bearer(String)
    case failed(UsageOutcome)
}

public struct ParseContext: Equatable, Sendable {
    public var grokModel: String
    public var accountLabel: String?

    public init(grokModel: String = "fast", accountLabel: String? = nil) {
        self.grokModel = grokModel
        self.accountLabel = accountLabel
    }
}

/// `parseUsage`: status + body → common model, including the 403 distinction.
public enum UsageParser {
    public static func parseUsage(
        provider: Provider,
        statusCode: Int,
        body: Data,
        endpoint: Endpoint = .usage,
        context: ParseContext = ParseContext()
    ) -> UsageOutcome {
        if let blocked = httpBlock(provider: provider, statusCode: statusCode, endpoint: endpoint, body: body) {
            return blocked
        }

        guard statusCode == 200 else {
            return .httpError(status: statusCode)
        }

        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return .notJSON
        }

        if endpoint == .bootstrap {
            return ClaudeParser.parseBootstrap(root)
        }

        if provider == .claude, let apiError = ClaudeParser.apiError(in: root) {
            return .notTrackable(message: apiError)
        }

        switch provider {
        case .claude:
            return ClaudeParser.parseUsage(root, accountLabel: context.accountLabel)
        case .chatGPT:
            return ChatGPTParser.parseUsage(root, accountLabel: context.accountLabel)
        case .grok:
            return GrokParser.parseUsage(root, model: context.grokModel, accountLabel: context.accountLabel)
        }
    }

    public static func claudeOrganizations(from data: Data) -> [ClaudeOrg] {
        ClaudeParser.parseBootstrapData(data)
    }

    /// Grok `GetGrokCreditsConfig`. Nil on any failure — the 2-hour windows
    /// stay; a silent miss must not paint Grok as "!".
    public static func parseGrokWeekly(body: Data) -> Limit? {
        GrokParser.parseWeekly(body)
    }

    /// Grok `GetRemainingResets`. Nil is a miss (do not display, do not
    /// store 0). `.none` is a successful empty list.
    public static func parseGrokRemainingResets(body: Data, now: Date = Date()) -> ResetRead? {
        GrokParser.parseRemainingResets(body, now: now)
    }

    /// ChatGPT `rate-limit-reset-credits`. Nil is a miss. `.none` is
    /// `available_count: 0`.
    public static func parseChatGPTResetCredits(body: Data) -> ResetRead? {
        ChatGPTParser.parseResetCredits(body)
    }

    /// ChatGPT `/api/auth/session` → bearer for `/backend-api/wham/usage`.
    /// A 200 without `accessToken` is expired. That field is the proof the cookie
    /// still mints a backend token — not a 401 on the usage call, which rejects
    /// cookies even when the session is live.
    public static func chatGPTAccessToken(statusCode: Int, body: Data) -> ChatGPTAuth {
        if statusCode == 401 { return .failed(.expired) }
        guard statusCode == 200 else { return .failed(.httpError(status: statusCode)) }
        return ChatGPTParser.parseAccessToken(body)
    }

    /// 401 everywhere = expired. 403 on Claude bootstrap = expired. 403 on Claude
    /// usage = that org is not trackable. 403 on ChatGPT/Grok is *not* expired —
    /// it may be a Cloudflare challenge, and treating it as logout greys a live session.
    private static func httpBlock(
        provider: Provider,
        statusCode: Int,
        endpoint: Endpoint,
        body: Data
    ) -> UsageOutcome? {
        if statusCode == 401 { return .expired }
        guard statusCode == 403 else { return nil }

        switch (provider, endpoint) {
        case (.claude, .bootstrap):
            return .expired
        case (.claude, .usage):
            let message = claudeErrorMessage(in: body) ?? "permission_error"
            return .notTrackable(message: message)
        case (_, _):
            return .httpError(status: 403)
        }
    }

    private static func claudeErrorMessage(in body: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return nil
        }
        return ClaudeParser.apiError(in: root)
    }
}
