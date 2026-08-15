import Foundation

enum JSONValue {
    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber:
            // JSON `true`/`false` arrive as NSNumber. A boolean is not a utilization.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return n.doubleValue
        case let s as String:
            return Double(s)
        default:
            return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            return n.intValue
        case let s as String:
            return Int(s)
        default:
            return nil
        }
    }

    static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String:
            return s.isEmpty ? nil : s
        default:
            return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool:
            return b
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID():
            return n.boolValue
        default:
            return nil
        }
    }

    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [[String: Any]]? {
        value as? [[String: Any]]
    }
}

enum DateParsing {
    /// Claude: `2026-08-17T00:59:59.562414+00:00` — six fractional digits.
    /// `ISO8601DateFormatter` wants three, so try fractional, then plain, then truncated.
    static func iso8601(_ value: Any?) -> Date? {
        guard let raw = JSONValue.string(value) else { return nil }
        if let d = isoFractional.date(from: raw) ?? isoPlain.date(from: raw) { return d }
        return isoFractional.date(from: truncatingFraction(raw))
    }

    /// ChatGPT: unix seconds, Int or Double.
    static func unixSeconds(_ value: Any?) -> Date? {
        guard let n = JSONValue.number(value) else { return nil }
        return Date(timeIntervalSince1970: n)
    }

    private static func truncatingFraction(_ raw: String) -> String {
        guard let dot = raw.firstIndex(of: ".") else { return raw }
        let afterDot = raw.index(after: dot)
        guard let end = raw[afterDot...].firstIndex(where: { !$0.isNumber }) else { return raw }
        let digits = raw[afterDot..<end]
        guard digits.count > 3 else { return raw }
        let kept = raw[afterDot..<raw.index(afterDot, offsetBy: 3)]
        return String(raw[raw.startIndex..<afterDot]) + kept + raw[end...]
    }

    /// Fresh per call: `ISO8601DateFormatter` is not `Sendable`.
    private static var isoFractional: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    private static var isoPlain: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }
}

enum WindowLabel {
    /// Turns a window length into something readable. Unknown lengths stay as seconds
    /// rather than being forced into a name we made up.
    static func from(seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "Fenster" }
        let s = Int(seconds.rounded())
        switch s {
        case 3600: return "1 Stunde"
        case 7200: return "2 Stunden"
        case 86400: return "Tag"
        case 604_800: return "Woche"
        default:
            if s % 86400 == 0 {
                let days = s / 86400
                return days == 1 ? "Tag" : "\(days) Tage"
            }
            if s % 3600 == 0 {
                let hours = s / 3600
                return hours == 1 ? "1 Stunde" : "\(hours) Stunden"
            }
            return "\(s) s"
        }
    }
}
