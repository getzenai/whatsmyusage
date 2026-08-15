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
