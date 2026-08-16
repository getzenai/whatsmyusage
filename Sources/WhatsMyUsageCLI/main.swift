import Foundation
import UsageBarCore

/// Read-only view of the app's measurement log. No network, no Keychain.
///
/// Exit codes: 0 ok (and `pick` found a usable account), 1 `pick` found none,
/// 2 usage / missing log / read error.
@main
enum WhatsMyUsageCLI {
    static func main() {
        do {
            let command = try Command.parse(Array(CommandLine.arguments.dropFirst()))
            switch command {
            case .help:
                FileHandle.standardOutput.write(Data(Command.helpText.utf8))
            case let .status(json, logURL):
                try runStatus(json: json, logURL: logURL)
            case let .pick(provider, json, logURL):
                try runPick(provider: provider, json: json, logURL: logURL)
            case let .achievements(json, logURL):
                try runAchievements(json: json, logURL: logURL)
            }
        } catch let error as CLIError {
            FileHandle.standardError.write(Data("\(error.message)\n".utf8))
            exit(Int32(error.exitCode))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(2)
        }
    }

    private static func runStatus(json: Bool, logURL: URL?) throws {
        let opened = try openLatest(logURL)
        let now = Date()
        let status = UsageQuery.status(from: opened.latest, now: now)
        if json {
            write(try UsageQuery.statusJSON(status))
            return
        }
        write(humanStatus(status, now: now, path: opened.url.path))
    }

    private static func runPick(provider: Provider?, json: Bool, logURL: URL?) throws {
        let opened = try openLatest(logURL)
        let now = Date()
        let pick = UsageQuery.pick(from: opened.latest, now: now, provider: provider)
        if json {
            write(try UsageQuery.pickJSON(pick))
        } else {
            write(humanPick(pick, now: now))
        }
        if !pick.found { throw CLIError("no usable account", exitCode: 1) }
    }

    private static func runAchievements(json: Bool, logURL: URL?) throws {
        let opened = try openLatest(logURL)
        let series = try opened.log.achievementSeries()
        let days = try opened.log.observedDays()
        let list = Achievements.evaluate(series: series, observedDays: days)
        let observedAt = opened.latest.map(\.observedAt).max()
        if json {
            write(try UsageQuery.achievementsJSON(list, observedAt: observedAt))
            return
        }
        write(humanAchievements(list, observedAt: observedAt, now: Date()))
    }

    private static func openLatest(_ explicit: URL?) throws -> (log: UsageLog, latest: [UsageMeasurement], url: URL) {
        let url = try explicit ?? UsageLog.defaultURL(create: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CLIError(
                "no usage log at \(url.path) — is the WhatsMyUsage app running and refreshed?",
                exitCode: 2
            )
        }
        let log: UsageLog
        do {
            log = try UsageLog(url: url, readOnly: true)
        } catch {
            throw CLIError("cannot open usage log: \(error)", exitCode: 2)
        }
        let latest: [UsageMeasurement]
        do {
            latest = try log.latestBySeries()
        } catch {
            throw CLIError("cannot read usage log: \(error)", exitCode: 2)
        }
        return (log, latest, url)
    }

    private static func write(_ data: Data) {
        var payload = data
        if payload.last != 0x0A { payload.append(0x0A) }
        FileHandle.standardOutput.write(payload)
    }

    private static func write(_ text: String) {
        write(Data(text.utf8))
    }

    private static func humanStatus(_ status: UsageQuery.Status, now: Date, path: String) -> String {
        var lines: [String] = []
        if let observedAt = status.observedAt {
            lines.append("observedAt \(UsageQuery.iso8601(observedAt))  \(agePhrase(observedAt, now: now))")
        } else {
            lines.append("observedAt unknown  (empty log)")
        }
        if status.accounts.isEmpty {
            lines.append("no accounts in \(path)")
            return lines.joined(separator: "\n")
        }
        for account in status.accounts {
            lines.append("")
            lines.append("\(account.provider.rawValue)  \(account.trackingID)  \(agePhrase(account.observedAt, now: now))")
            for limit in account.limits {
                let util = limit.utilization.map { BarPresentation.percentString($0) } ?? "unknown"
                let locked = limit.locked?.rawValue ?? "unknown"
                let reset = limit.resetsAt.map(UsageQuery.iso8601) ?? "—"
                lines.append(
                    "  \(pad(limit.limitID, 28))  \(pad(util, 8))  locked \(pad(locked, 9))  resetsAt \(reset)"
                )
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func humanPick(_ pick: UsageQuery.Pick, now: Date) -> String {
        let age = pick.observedAt.map { agePhrase($0, now: now) } ?? "observedAt unknown"
        guard let trackingID = pick.trackingID, let provider = pick.provider else {
            let reset = pick.resetsAt.map { "next reset \(UsageQuery.iso8601($0))" } ?? "next reset unknown"
            return "none usable  \(reset)  \(age)"
        }
        let util = pick.utilization.map { BarPresentation.percentString($0) } ?? "unknown"
        let reset = pick.resetsAt.map { "resetsAt \(UsageQuery.iso8601($0))" } ?? "resetsAt —"
        return "\(provider.rawValue)  \(trackingID)  \(util)  \(reset)  \(age)"
    }

    private static func humanAchievements(
        _ list: [Achievements.Achievement],
        observedAt: Date?,
        now: Date
    ) -> String {
        var lines: [String] = []
        if let observedAt {
            lines.append("observedAt \(UsageQuery.iso8601(observedAt))  \(agePhrase(observedAt, now: now))")
        } else {
            lines.append("observedAt unknown  (empty log)")
        }
        for item in list {
            let mark = item.isEarned ? "earned" : "locked"
            let when = item.earnedAt.map { "  \(UsageQuery.iso8601($0))" } ?? ""
            lines.append("\(mark)  \(item.title)\(when)")
            lines.append("        \(item.detail)")
        }
        return lines.joined(separator: "\n")
    }

    private static func agePhrase(_ observedAt: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(observedAt)
        if UsageQuery.isStale(observedAt, now: now) {
            return "stale \(formatAge(seconds))"
        }
        return "age \(formatAge(seconds))"
    }

    private static func formatAge(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(max(0, whole))s" }
        if whole < 3600 { return "\(whole / 60)m" }
        return "\(whole / 3600)h"
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        if text.count >= width { return text }
        return text + String(repeating: " ", count: width - text.count)
    }
}

private struct CLIError: Error {
    let message: String
    let exitCode: Int
    init(_ message: String, exitCode: Int) {
        self.message = message
        self.exitCode = exitCode
    }
}

private enum Command {
    case status(json: Bool, log: URL?)
    case pick(provider: Provider?, json: Bool, log: URL?)
    case achievements(json: Bool, log: URL?)
    case help

    static let helpText = """
    whatsmyusage — read the WhatsMyUsage measurement log

    The CLI only reads usage-log.sqlite. It does not touch the network or the
    Keychain. Numbers older than 5 minutes + 90 seconds are unknown.

    Usage:
      whatsmyusage status [--json]
      whatsmyusage pick [--provider claude|chatGPT|grok] [--json]
      whatsmyusage achievements [--json]
      whatsmyusage --help

    Optional: --log PATH  (default: the running app's usage-log.sqlite)

    Exit codes:
      0  ok (`pick`: an account still has room)
      1  `pick`: every account is blocked or stale
      2  missing log, bad arguments, or a read error

    """

    static func parse(_ args: [String]) throws -> Command {
        if args.isEmpty || args.contains("-h") || args.contains("--help") {
            return .help
        }
        var rest = args
        let verb = rest.removeFirst()
        let json = takeFlag(&rest, "--json")
        let log = try takeValue(&rest, "--log").map { URL(fileURLWithPath: $0) }
        switch verb {
        case "status":
            try ensureEmpty(rest)
            return .status(json: json, log: log)
        case "pick":
            let raw = try takeValue(&rest, "--provider")
            try ensureEmpty(rest)
            return .pick(provider: try raw.map(parseProvider), json: json, log: log)
        case "achievements":
            try ensureEmpty(rest)
            return .achievements(json: json, log: log)
        default:
            throw CLIError("unknown command \(verb)\n\n\(helpText)", exitCode: 2)
        }
    }

    private static func parseProvider(_ raw: String) throws -> Provider {
        switch raw.lowercased() {
        case "claude": return .claude
        case "chatgpt": return .chatGPT
        case "grok": return .grok
        default:
            throw CLIError("unknown provider \(raw) (claude, chatGPT, grok)", exitCode: 2)
        }
    }

    private static func takeFlag(_ args: inout [String], _ name: String) -> Bool {
        if let index = args.firstIndex(of: name) {
            args.remove(at: index)
            return true
        }
        return false
    }

    private static func takeValue(_ args: inout [String], _ name: String) throws -> String? {
        guard let index = args.firstIndex(of: name) else { return nil }
        let valueIndex = index + 1
        guard valueIndex < args.count else {
            throw CLIError("\(name) needs a value", exitCode: 2)
        }
        let value = args[valueIndex]
        args.removeSubrange(index...valueIndex)
        return value
    }

    private static func ensureEmpty(_ args: [String]) throws {
        guard args.isEmpty else {
            throw CLIError("unexpected arguments: \(args.joined(separator: " "))", exitCode: 2)
        }
    }
}
