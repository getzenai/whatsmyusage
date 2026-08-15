import Foundation
import SQLite3

/// One measured limit at one point in time — the raw row the app writes on every refresh.
///
/// Every reading becomes a row, not just the changes. A state-change log has to decide
/// at write time what counts as a change, and deciding wrong loses data for good. With
/// raw rows a wrong decision is a wrong query, which is fixable. The volume is small:
/// one refresh every five minutes over roughly ten limits is ~3.000 rows a day.
public struct UsageMeasurement: Equatable, Sendable {
    public let observedAt: Date
    public let provider: Provider
    /// Stable per-account id. Together with `limitID` this is the series key.
    public let trackingID: String
    public let limitID: String
    public let label: String
    public let utilization: Double
    public let resetsAt: Date?
    public let locked: LockState
    public let scope: LimitScope
    public let severity: LimitSeverity

    public init(
        observedAt: Date,
        provider: Provider,
        trackingID: String,
        limitID: String,
        label: String,
        utilization: Double,
        resetsAt: Date?,
        locked: LockState,
        scope: LimitScope,
        severity: LimitSeverity
    ) {
        self.observedAt = observedAt
        self.provider = provider
        self.trackingID = trackingID
        self.limitID = limitID
        self.label = label
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.locked = locked
        self.scope = scope
        self.severity = severity
    }

    /// The account label (org name, plan) is deliberately absent: it is display-only
    /// and changes under us. `trackingID` is what stays the same across renames.
    public init(observedAt: Date, provider: Provider, trackingID: String, limit: Limit) {
        self.init(
            observedAt: observedAt,
            provider: provider,
            trackingID: trackingID,
            limitID: limit.id,
            label: limit.label,
            utilization: limit.utilization,
            resetsAt: limit.resetsAt,
            locked: limit.locked,
            scope: limit.scope,
            severity: limit.severity
        )
    }
}

public enum UsageLogError: Error, Equatable {
    case open(String)
    case sql(String)
}

/// The append-only measurement log, in SQLite next to the app's other local state.
///
/// Not Sendable on purpose: the app writes from the main actor, tests own their own
/// instance. One connection, no cross-thread sharing, no locking to get wrong.
public final class UsageLog {
    private var db: OpaquePointer?

    /// `~/Library/Application Support/WhatsMyUsage/usage-log.sqlite`.
    public static func defaultURL(
        appName: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support.appendingPathComponent(appName, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("usage-log.sqlite")
    }

    public init(url: URL) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(url.path)"
            sqlite3_close_v2(handle)
            throw UsageLogError.open(message)
        }
        db = handle
        // WAL so a reader (a future graph view) never blocks the writer.
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try migrate()
    }

    deinit {
        sqlite3_close_v2(db)
    }

    // MARK: - Schema

    private func migrate() throws {
        if try userVersion() < 1 {
            try exec("""
                CREATE TABLE IF NOT EXISTS measurements (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    observed_at REAL NOT NULL,
                    provider TEXT NOT NULL,
                    tracking_id TEXT NOT NULL,
                    limit_id TEXT NOT NULL,
                    label TEXT NOT NULL,
                    utilization REAL NOT NULL,
                    resets_at REAL,
                    locked TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    severity TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS measurements_series
                    ON measurements (tracking_id, limit_id, observed_at);
                CREATE INDEX IF NOT EXISTS measurements_time
                    ON measurements (observed_at);
                """)
            try exec("PRAGMA user_version=1;")
        }
    }

    private func userVersion() throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK else {
            throw UsageLogError.sql(lastMessage())
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - Writing

    /// Append one refresh. All rows share the same `observedAt`, so a whole refresh
    /// can be read back as one column of the timeline.
    @discardableResult
    public func record(_ snapshots: [UsageSnapshot], at observedAt: Date) throws -> Int {
        let rows = snapshots.flatMap { snapshot in
            snapshot.limits.map {
                UsageMeasurement(
                    observedAt: observedAt,
                    provider: snapshot.provider,
                    trackingID: snapshot.trackingID,
                    limit: $0
                )
            }
        }
        try append(rows)
        return rows.count
    }

    public func append(_ measurements: [UsageMeasurement]) throws {
        guard !measurements.isEmpty else { return }
        let sql = """
            INSERT INTO measurements
                (observed_at, provider, tracking_id, limit_id, label,
                 utilization, resets_at, locked, scope, severity)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw UsageLogError.sql(lastMessage())
        }
        defer { sqlite3_finalize(statement) }

        // One transaction per refresh: either the whole reading lands or none of it,
        // so a crash mid-write cannot leave half a column in the timeline.
        try exec("BEGIN IMMEDIATE;")
        do {
            for row in measurements {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_double(statement, 1, row.observedAt.timeIntervalSince1970)
                bind(statement, 2, row.provider.rawValue)
                bind(statement, 3, row.trackingID)
                bind(statement, 4, row.limitID)
                bind(statement, 5, row.label)
                sqlite3_bind_double(statement, 6, row.utilization)
                if let resetsAt = row.resetsAt {
                    sqlite3_bind_double(statement, 7, resetsAt.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(statement, 7)
                }
                bind(statement, 8, row.locked.rawValue)
                bind(statement, 9, row.scope.rawValue)
                bind(statement, 10, row.severity.rawValue)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw UsageLogError.sql(lastMessage())
                }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Reading

    /// Every reading of one series, oldest first. `since` is inclusive.
    public func series(
        trackingID: String,
        limitID: String,
        since: Date? = nil,
        until: Date? = nil
    ) throws -> [UsageMeasurement] {
        var sql = """
            SELECT observed_at, provider, tracking_id, limit_id, label,
                   utilization, resets_at, locked, scope, severity
            FROM measurements
            WHERE tracking_id = ? AND limit_id = ?
            """
        if since != nil { sql += " AND observed_at >= ?" }
        if until != nil { sql += " AND observed_at <= ?" }
        sql += " ORDER BY observed_at ASC, id ASC;"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw UsageLogError.sql(lastMessage())
        }
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, trackingID)
        bind(statement, 2, limitID)
        var index: Int32 = 3
        if let since {
            sqlite3_bind_double(statement, index, since.timeIntervalSince1970)
            index += 1
        }
        if let until {
            sqlite3_bind_double(statement, index, until.timeIntervalSince1970)
        }
        return try rows(from: statement)
    }

    /// Every reading in a window, oldest first — the input for graphs over all limits.
    public func measurements(since: Date, until: Date? = nil) throws -> [UsageMeasurement] {
        var sql = """
            SELECT observed_at, provider, tracking_id, limit_id, label,
                   utilization, resets_at, locked, scope, severity
            FROM measurements
            WHERE observed_at >= ?
            """
        if until != nil { sql += " AND observed_at <= ?" }
        sql += " ORDER BY observed_at ASC, id ASC;"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw UsageLogError.sql(lastMessage())
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
        if let until {
            sqlite3_bind_double(statement, 2, until.timeIntervalSince1970)
        }
        return try rows(from: statement)
    }

    /// Which series the log knows about at all.
    public func knownSeries() throws -> [(trackingID: String, limitID: String)] {
        let sql = """
            SELECT DISTINCT tracking_id, limit_id FROM measurements
            ORDER BY tracking_id ASC, limit_id ASC;
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw UsageLogError.sql(lastMessage())
        }
        defer { sqlite3_finalize(statement) }
        var result: [(trackingID: String, limitID: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((text(statement, 0), text(statement, 1)))
        }
        return result
    }

    public func count() throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM measurements;", -1, &statement, nil) == SQLITE_OK else {
            throw UsageLogError.sql(lastMessage())
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    // MARK: - Plumbing

    private func rows(from statement: OpaquePointer?) throws -> [UsageMeasurement] {
        var result: [UsageMeasurement] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                result.append(measurement(from: statement))
            case SQLITE_DONE:
                return result
            default:
                throw UsageLogError.sql(lastMessage())
            }
        }
    }

    private func measurement(from statement: OpaquePointer?) -> UsageMeasurement {
        UsageMeasurement(
            observedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
            provider: Provider(rawValue: text(statement, 1)) ?? .claude,
            trackingID: text(statement, 2),
            limitID: text(statement, 3),
            label: text(statement, 4),
            utilization: sqlite3_column_double(statement, 5),
            resetsAt: sqlite3_column_type(statement, 6) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            locked: LockState(rawValue: text(statement, 7)) ?? .unknown,
            scope: LimitScope(rawValue: text(statement, 8)) ?? .account,
            severity: LimitSeverity(rawValue: text(statement, 9)) ?? .unknown
        )
    }

    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: raw)
    }

    /// SQLITE_TRANSIENT: sqlite copies the bytes, so the Swift String may die right after.
    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw UsageLogError.sql(lastMessage())
        }
    }

    private func lastMessage() -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database"
    }
}
