import Foundation
import UsageBarCore
import os

/// Owns the one `UsageLog` the app writes to and keeps it out of the refresh path's
/// way: a broken log must never stop the bar from showing a number.
@MainActor
final class UsageLogWriter {
    private static let logger = Logger(subsystem: AppIdentity.bundleID, category: "usage-log")
    private var log: UsageLog?
    private var openFailed = false

    /// Nil until the first refresh, and after an open that failed — the caller decides
    /// whether an unavailable history is worth mentioning.
    var store: UsageLog? {
        guard !openFailed else { return nil }
        if let log { return log }
        do {
            let url = try UsageLog.defaultURL(appName: AppIdentity.displayName)
            let opened = try UsageLog(url: url)
            log = opened
            return opened
        } catch {
            // Once, not on every refresh — a disk problem should not fill the log
            // with a line every five minutes.
            openFailed = true
            Self.logger.error("cannot open usage log: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func record(_ byProvider: [Provider: [UsageOutcome]], at date: Date = Date()) {
        // Only real readings. An expired cookie or an HTTP error is not a measurement
        // of zero usage, and writing it as one would bend every later graph.
        let snapshots = byProvider.values.flatMap { $0 }.compactMap { outcome -> UsageSnapshot? in
            guard case let .snapshot(snapshot) = outcome, !snapshot.limits.isEmpty else { return nil }
            return snapshot
        }
        guard !snapshots.isEmpty, let store else { return }
        do {
            try store.record(snapshots, at: date)
        } catch {
            Self.logger.error("cannot write usage log: \(String(describing: error), privacy: .public)")
        }
    }
}
