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
            case let .status(json, limits, logURL, printUsage):
                try runStatus(json: json, limits: limits, logURL: logURL, printUsage: printUsage)
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

    private static func runStatus(json: Bool, limits: Bool, logURL: URL?, printUsage: Bool) throws {
        let opened = try openLatest(logURL)
        let now = Date()
        let status = UsageQuery.status(from: opened.latest, now: now)
        if json {
            write(try UsageQuery.statusJSON(status))
            return
        }
        let pick = UsageQuery.pick(from: opened.latest, now: now)
        let body = HumanStatus.render(
            status: status,
            pick: pick,
            names: names(),
            now: now,
            showLimits: limits,
            preferences: DisplayPreferences.loadFromAppSuite()
        )
        if printUsage {
            write(Command.usageBlock + "\n\n" + body)
        } else {
            write(body)
        }
    }

    private static func runPick(provider: Provider?, json: Bool, logURL: URL?) throws {
        let opened = try openLatest(logURL)
        let now = Date()
        let pick = UsageQuery.pick(from: opened.latest, now: now, provider: provider)
        if json {
            write(try UsageQuery.pickJSON(pick))
        } else {
            let status = UsageQuery.status(from: opened.latest, now: now)
            write(HumanStatus.renderPick(pick, status: status, names: names(), now: now))
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

    private static func names() -> HumanStatus.Names {
        let maps = AccountDisplayNames.loadFromAppSuite()
        return HumanStatus.Names(custom: maps.custom, defaults: maps.defaults)
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
        if latest.isEmpty {
            throw CLIError(
                "no readings in the log — is WhatsMyUsage running and refreshed?",
                exitCode: 2
            )
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

    private static func humanAchievements(
        _ list: [Achievements.Achievement],
        observedAt: Date?,
        now: Date
    ) -> String {
        var lines: [String] = []
        if let observedAt {
            let age = UsageQuery.isStale(observedAt, now: now) ? "stale" : "fresh"
            lines.append("\(age)")
        }
        for item in list {
            let mark = item.isEarned ? "earned" : "locked"
            lines.append("\(mark)  \(item.title)")
            // Same two lines as the window: the rule always, plus the state.
            // JSON keeps `detail` as the state and adds `requirement` next to it.
            if item.isEarned {
                lines.append("        \(item.detail)")
                if item.detail != item.requirement {
                    lines.append("        \(item.requirement)")
                }
            } else {
                lines.append("        \(item.requirement)")
                if item.detail != item.requirement {
                    lines.append("        \(item.detail)")
                }
            }
        }
        return lines.joined(separator: "\n")
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
    case status(json: Bool, limits: Bool, log: URL?, printUsage: Bool)
    case pick(provider: Provider?, json: Bool, log: URL?)
    case achievements(json: Bool, log: URL?)
    case help

    static let usageBlock = """
    Usage:
      whatsmyusage status [--json] [--limits]
      whatsmyusage pick [--provider claude|chatGPT|grok] [--json]
      whatsmyusage achievements [--json]
      whatsmyusage --help
    """

    static let helpText = """
    whatsmyusage — which account has room

    \(usageBlock)

    `pick` treats a full model-scoped limit as blocking. Claude `locked` is
    always unknown — read utilization.

    Optional: --log PATH

    Exit codes:
      0  ok (`pick`: an account still has room)
      1  `pick`: every account is blocked or stale
      2  missing log, empty log, bad arguments, or a read error

    """

    static func parse(_ args: [String]) throws -> Command {
        if args.contains("-h") || args.contains("--help") {
            return .help
        }
        if args.isEmpty {
            return .status(json: false, limits: false, log: nil, printUsage: true)
        }
        var rest = args
        let verb: String
        if rest[0].hasPrefix("-") {
            verb = "status"
        } else {
            verb = rest.removeFirst()
        }
        let json = takeFlag(&rest, "--json")
        let log = try takeValue(&rest, "--log").map { URL(fileURLWithPath: $0) }
        switch verb {
        case "status":
            let limits = takeFlag(&rest, "--limits")
            try ensureEmpty(rest)
            return .status(json: json, limits: limits, log: log, printUsage: false)
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
