import Foundation

public struct ClaudeCredentials: Equatable, Sendable {
    public let sessionKey: String
    /// Convenience only. The org list comes from `/api/bootstrap`; this just
    /// pre-selects the matching one.
    public let lastActiveOrg: String?

    public init(sessionKey: String, lastActiveOrg: String? = nil) {
        self.sessionKey = sessionKey
        self.lastActiveOrg = lastActiveOrg
    }

    /// Measured 2026-08-15: `sessionKey` alone is enough. No `cf_clearance`, no UA spoof.
    public var cookieHeader: String { "sessionKey=\(sessionKey)" }
}

public struct ChatGPTCredentials: Equatable, Sendable {
    /// Numbered cookie parts, already sorted by index. Empty when the paste was an
    /// unchunked `session-token`.
    public let parts: [CookiePart]
    public let assembled: String

    public struct CookiePart: Equatable, Sendable {
        public let index: Int
        public let value: String
        public init(index: Int, value: String) {
            self.index = index
            self.value = value
        }
    }

    public init(parts: [CookiePart], assembled: String) {
        self.parts = parts
        self.assembled = assembled
    }

    /// Sent the way the browser sends them: numbered cookies, not one assembled value.
    /// The server reassembles. Sending the joined token as a single cookie is the
    /// path that silently 401s.
    public var cookieHeader: String {
        if parts.isEmpty {
            return "__Secure-next-auth.session-token=\(assembled)"
        }
        return parts
            .map { "__Secure-next-auth.session-token.\($0.index)=\($0.value)" }
            .joined(separator: "; ")
    }
}

public struct GrokCredentials: Equatable, Sendable {
    public let sso: String

    public init(sso: String) {
        self.sso = sso
    }

    public var cookieHeader: String { "sso=\(sso)" }
}

public struct ExtractedCredentials: Equatable, Sendable {
    public var claude: ClaudeCredentials?
    public var chatGPT: ChatGPTCredentials?
    public var grok: GrokCredentials?

    public init(claude: ClaudeCredentials? = nil, chatGPT: ChatGPTCredentials? = nil, grok: GrokCredentials? = nil) {
        self.claude = claude
        self.chatGPT = chatGPT
        self.grok = grok
    }

    public var isEmpty: Bool { claude == nil && chatGPT == nil && grok == nil }

    public var configuredProviders: [Provider] {
        var result: [Provider] = []
        if claude != nil { result.append(.claude) }
        if chatGPT != nil { result.append(.chatGPT) }
        if grok != nil { result.append(.grok) }
        return result
    }
}

public enum CookieExtractionError: Error, Equatable {
    case nothingFound
}

/// `extractSessionKey`: cookie text → provider keys, including ChatGPT's numbered parts.
public enum SessionCookies {
    private static let claudeKeyNames: Set<String> = ["sessionKey", "sessionKeyV3"]
    private static let orgNames: Set<String> = ["lastActiveOrg"]
    /// Narrower than `sk-ant-`: `routingHint` in the same paste starts with `sk-ant-rh-`.
    private static let claudePrefix = "sk-ant-sid"
    /// `__Secure-` / `__Host-` prefix, then `next-auth.session-token` plus optional `.N`.
    /// Parsed by hand: `Regex` is not `Sendable`, so it cannot live in a static let.

    public static func extractSessionKey(from pasted: String) throws -> ExtractedCredentials {
        let pairs = namedValues(in: pasted)
        var extracted = ExtractedCredentials()

        extracted.claude = extractClaude(from: pairs, pasted: pasted)
        extracted.chatGPT = extractChatGPT(from: pairs)
        extracted.grok = extractGrok(from: pairs)

        if extracted.isEmpty { throw CookieExtractionError.nothingFound }
        return extracted
    }

    // MARK: - Claude

    private static func extractClaude(from pairs: [NamedValue], pasted: String) -> ClaudeCredentials? {
        var sessionKey = pairs.first { claudeKeyNames.contains($0.name) && isClaudeKey($0.value) }?.value
        if sessionKey == nil {
            sessionKey = tokens(in: pasted).first(where: isClaudeKey)
        }
        guard let sessionKey else { return nil }
        let org = pairs.first { orgNames.contains($0.name) && UUID(uuidString: $0.value) != nil }?.value
        return ClaudeCredentials(sessionKey: sessionKey, lastActiveOrg: org)
    }

    private static func isClaudeKey(_ value: String) -> Bool {
        // Measured key is ~108 characters. A truncated paste must fail here, not
        // later as a 401 that looks like "expired".
        value.hasPrefix(claudePrefix) && value.count >= 40
    }

    // MARK: - ChatGPT

    private static func extractChatGPT(from pairs: [NamedValue]) -> ChatGPTCredentials? {
        var numbered: [ChatGPTCredentials.CookiePart] = []
        var unchunked: String?

        for pair in pairs {
            guard let parsed = chatGPTToken(named: pair.name) else { continue }
            guard pair.value.count >= 20 else { continue }
            if let index = parsed {
                numbered.append(.init(index: index, value: pair.value))
            } else {
                unchunked = pair.value
            }
        }

        if !numbered.isEmpty {
            // Last write per index wins; then sort numerically (`.10` after `.2`).
            var byIndex: [Int: String] = [:]
            for part in numbered { byIndex[part.index] = part.value }
            let parts = byIndex.keys.sorted().map { ChatGPTCredentials.CookiePart(index: $0, value: byIndex[$0]!) }
            return ChatGPTCredentials(parts: parts, assembled: parts.map(\.value).joined())
        }
        if let unchunked {
            return ChatGPTCredentials(parts: [], assembled: unchunked)
        }
        return nil
    }

    /// `nil` = not a session token. `.some(nil)` = unchunked token. `.some(N)` = part N.
    private static func chatGPTToken(named name: String) -> Int?? {
        var rest = name[...]
        if rest.hasPrefix("__Secure-") {
            rest = rest.dropFirst("__Secure-".count)
        } else if rest.hasPrefix("__Host-") {
            rest = rest.dropFirst("__Host-".count)
        }
        let stem = "next-auth.session-token"
        guard rest.hasPrefix(stem) else { return nil }
        rest = rest.dropFirst(stem.count)
        if rest.isEmpty { return .some(nil) }
        guard rest.first == "." else { return nil }
        rest = rest.dropFirst()
        guard let index = Int(rest) else { return nil }
        return .some(index)
    }

    // MARK: - Grok

    private static func extractGrok(from pairs: [NamedValue]) -> GrokCredentials? {
        // Prefer a row whose domain is grok.com. Fall back to the name `sso`
        // only when no domain is attached — a Safari table from chatgpt.com
        // should not donate a stray cookie of the same name.
        let candidates = pairs.filter { $0.name == "sso" && $0.value.count >= 8 }
        if let grok = candidates.first(where: { domain in
            domain.domain?.localizedCaseInsensitiveContains("grok.com") == true
        }) {
            return GrokCredentials(sso: grok.value)
        }
        if let bare = candidates.first(where: { $0.domain == nil }) {
            return GrokCredentials(sso: bare.value)
        }
        return nil
    }

    // MARK: - Split

    private struct NamedValue {
        let name: String
        let value: String
        let domain: String?
    }

    /// Recognises `name=value` (request header, `document.cookie`) and
    /// `name<TAB>value<TAB>domain…` (Safari / DevTools cookie table).
    private static func namedValues(in text: String) -> [NamedValue] {
        var result: [NamedValue] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if columns.count >= 2, !columns[0].isEmpty, !columns[1].isEmpty, !columns[0].contains("=") {
                let domain = columns.count >= 3 && !columns[2].isEmpty ? columns[2] : nil
                result.append(NamedValue(name: columns[0], value: columns[1], domain: domain))
                continue
            }
            var body = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["Cookie:", "cookie:", "Set-Cookie:"] where body.hasPrefix(prefix) {
                body = String(body.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            for part in body.split(separator: ";") {
                let piece = part.trimmingCharacters(in: .whitespaces)
                guard let eq = piece.firstIndex(of: "=") else { continue }
                let name = String(piece[piece.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
                let value = String(piece[piece.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, !value.isEmpty else { continue }
                result.append(NamedValue(name: name, value: value, domain: nil))
            }
        }
        return result
    }

    private static func tokens(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == ";" || $0 == "," })
            .map { String($0) }
    }
}
