import Foundation
import Testing
@testable import UsageBarCore

private func parse(_ json: String, status: Int = 200, model: String = "fast") -> UsageOutcome {
    UsageParser.parseUsage(
        provider: .grok,
        statusCode: status,
        body: Data(json.utf8),
        context: ParseContext(grokModel: model)
    )
}

private func snapshot(_ json: String, model: String = "fast") throws -> UsageSnapshot {
    let outcome = parse(json, model: model)
    guard case .snapshot(let snap) = outcome else {
        Issue.record("expected snapshot, got \(outcome)")
        throw UsageOutcomeMismatch()
    }
    return snap
}

private struct UsageOutcomeMismatch: Error {}

@Suite("Grok parseUsage")
struct GrokParserTests {

    @Test func unusedWindowIsZeroAndUnlocked() throws {
        let snap = try snapshot(Fixtures.grokUnused)
        let limit = try #require(snap.limits.first)
        #expect(limit.utilization == 0)
        #expect(limit.locked == .unlocked)
        #expect(limit.label == "Fast · 2 hours")
        #expect(limit.resetsAt == nil)
        #expect(limit.id == "fast")
    }

    @Test func zeroRemainingIsLockedAndFull() throws {
        let snap = try snapshot(Fixtures.grokEmpty)
        let limit = try #require(snap.limits.first)
        #expect(limit.utilization == 1)
        #expect(limit.locked == .locked)
    }

    @Test func utilizationIsComputedNotTakenFromTheProvider() throws {
        let snap = try snapshot(#"{"remainingQueries": 27, "totalQueries": 270, "windowSizeSeconds": 7200}"#)
        #expect(abs((snap.limits.first?.utilization ?? -1) - 0.9) < 0.0001)
    }

    @Test func modelNameIsNotHardcoded() throws {
        let snap = try snapshot(Fixtures.grokUnused, model: "expert")
        #expect(snap.limits.first?.id == "expert")
        #expect(snap.limits.first?.label == "Expert · 2 hours")
    }

    @Test func nestedWindowsArePickedUpByShape() throws {
        let json = """
        {"remainingQueries": 10, "totalQueries": 10, "windowSizeSeconds": 7200,
         "lowEffortRateLimits": {"remainingQueries": 1, "totalQueries": 2, "windowSizeSeconds": 7200}}
        """
        let snap = try snapshot(json)
        #expect(snap.limits.map(\.id) == ["fast", "fast/lowEffortRateLimits"])
        #expect(snap.limits.first { $0.id == "fast/lowEffortRateLimits" }?.utilization == 0.5)
    }

    @Test func divideByZeroIsEmpty() {
        #expect(parse(#"{"remainingQueries": 0, "totalQueries": 0}"#) == .empty)
    }

    @Test func forbiddenIsNotExpired() {
        #expect(parse("{}", status: 403) == .httpError(status: 403))
    }

    @Test func weeklyCreditsUsePercentAndReset() throws {
        let body = GrokWeeklyWire.frame(
            percent: 37.5,
            period: 2,
            resetSeconds: 1_800_000_000
        )
        let limit = try #require(UsageParser.parseGrokWeekly(body: body))
        #expect(limit.id == "weekly")
        #expect(limit.label == "Week")
        #expect(limit.scope == .account)
        #expect(limit.locked == .unknown)
        #expect(abs(limit.utilization - 0.375) < 0.0001)
        #expect(limit.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func weeklyAtOneHundredIsLocked() throws {
        let body = GrokWeeklyWire.frame(percent: 100, period: 2, resetSeconds: 1_800_000_000)
        let limit = try #require(UsageParser.parseGrokWeekly(body: body))
        #expect(limit.locked == .locked)
        #expect(limit.utilization == 1)
    }

    @Test func emptyFrameIsOmitted() {
        #expect(UsageParser.parseGrokWeekly(body: GrpcWeb.emptyRequest) == nil)
    }

    @Test func trailerWithoutDataFrameIsOmitted() {
        let trailer = GrpcWeb.frame(flag: 0x80, payload: Data("grpc-status:0\r\n".utf8))
        #expect(UsageParser.parseGrokWeekly(body: trailer) == nil)
    }

    @Test func nonWeeklyPeriodIsOmitted() {
        let monthly = GrokWeeklyWire.frame(percent: 37.5, period: 1, resetSeconds: 1_800_000_000)
        #expect(UsageParser.parseGrokWeekly(body: monthly) == nil)
    }

    @Test func truncatedVarintIsOmitted() {
        // Field 1, length-delimited, length varint continues past the buffer.
        let payload = Data([0x0A, 0x80])
        #expect(UsageParser.parseGrokWeekly(body: GrpcWeb.encode(message: payload)) == nil)
        #expect(Proto.decode(payload) == nil)
    }

    /// Proto3 drops a numeric field at 0. Period present and weekly means the
    /// provider answered — missing 1.1 is 0 %, not "no weekly limit".
    /// Code reading + proto3 rule, not a live 0 % account.
    @Test func remainingResetsEmptyFrameIsNoneNotZero() {
        // Live misshapen-looking 0-byte data frame is a successful empty list.
        let framed = UsageParser.parseGrokRemainingResets(body: GrpcWeb.encode(message: Data()))
        let requestShape = UsageParser.parseGrokRemainingResets(body: GrpcWeb.emptyRequest)
        #expect(framed == .none)
        #expect(requestShape == .none)
        #expect(framed?.count == nil)
    }

    @Test func remainingResetsMissingFrameIsOmitted() {
        let trailer = GrpcWeb.frame(flag: 0x80, payload: Data("grpc-status:0\r\n".utf8))
        #expect(UsageParser.parseGrokRemainingResets(body: trailer) == nil)
        let failed = GrpcWeb.encode(message: Data(), trailerStatus: 13)
        #expect(UsageParser.parseGrokRemainingResets(body: failed) == nil)
    }

    @Test func remainingResetsCountsUnexpiredTokensRegardlessOfOrder() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = GrokResetWire.token(id: "a", end: 1_800_000_100)
        let past = GrokResetWire.token(id: "b", end: 1_799_999_000)
        let other = GrokResetWire.token(id: "c", end: 1_800_000_200)
        let forward = UsageParser.parseGrokRemainingResets(
            body: GrokResetWire.frame(tokens: [future, past, other]),
            now: now
        )
        let backward = UsageParser.parseGrokRemainingResets(
            body: GrokResetWire.frame(tokens: [other, past, future]),
            now: now
        )
        #expect(forward == .available(2))
        #expect(backward == .available(2))
        #expect(ResetRead.label(for: 2) == "2 resets available")
    }

    @Test func remainingResetsSkipsEmptyIdAndMissingEnd() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let emptyID = GrokResetWire.token(id: "", end: 1_800_000_100)
        let noEnd = GrokResetWire.field(10, string: "keep")
        let body = GrokResetWire.frame(tokens: [emptyID, noEnd])
        #expect(UsageParser.parseGrokRemainingResets(body: body, now: now) == .none)
    }

    @Test func remainingResetsOneTokenLabel() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let body = GrokResetWire.frame(tokens: [GrokResetWire.token(id: "a", end: 1_800_000_100)])
        let read = UsageParser.parseGrokRemainingResets(body: body, now: now)
        #expect(read == .available(1))
        #expect(ResetRead.label(for: 1) == "Reset available")
    }

    @Test func omittedPercentOnWeeklyPeriodIsZero() throws {
        let body = GrokWeeklyWire.frameOmittingPercent(period: 2, resetSeconds: 1_800_000_000)
        let limit = try #require(UsageParser.parseGrokWeekly(body: body))
        #expect(limit.id == "weekly")
        #expect(limit.utilization == 0)
        #expect(limit.locked == .unknown)
        #expect(limit.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
    }
}

/// Builds placeholder GetGrokCreditsConfig bodies. Values are invented.
private enum GrokWeeklyWire {
    static func frame(percent: Float, period: UInt64, resetSeconds: UInt64) -> Data {
        let timestamp = field(1, varint: resetSeconds)
        let currentPeriod = field(1, varint: period) + field(3, message: timestamp)
        let config = field(1, float: percent) + field(8, message: currentPeriod)
        return GrpcWeb.encode(message: field(1, message: config))
    }

    /// Weekly period present, percent field absent — the proto3 default-0 wire.
    static func frameOmittingPercent(period: UInt64, resetSeconds: UInt64) -> Data {
        let timestamp = field(1, varint: resetSeconds)
        let currentPeriod = field(1, varint: period) + field(3, message: timestamp)
        let config = field(8, message: currentPeriod)
        return GrpcWeb.encode(message: field(1, message: config))
    }

    static func field(_ number: UInt64, varint value: UInt64) -> Data {
        encodeVarint((number << 3) | 0) + encodeVarint(value)
    }

    static func field(_ number: UInt64, float value: Float) -> Data {
        var bits = value.bitPattern.littleEndian
        return encodeVarint((number << 3) | 5) + Data(bytes: &bits, count: 4)
    }

    static func field(_ number: UInt64, message: Data) -> Data {
        encodeVarint((number << 3) | 2) + encodeVarint(UInt64(message.count)) + message
    }

    static func encodeVarint(_ value: UInt64) -> Data {
        var n = value
        var out = Data()
        while n >= 0x80 {
            out.append(UInt8(n & 0x7F) | 0x80)
            n >>= 7
        }
        out.append(UInt8(n))
        return out
    }
}

/// Placeholder GetRemainingResets bodies. Field numbers from consumer_ui.proto.
private enum GrokResetWire {
    static func frame(tokens: [Data]) -> Data {
        var message = Data()
        for token in tokens {
            message += field(10, message: token)
        }
        return GrpcWeb.encode(message: message)
    }

    static func token(id: String, end: UInt64) -> Data {
        field(10, string: id) + field(30, message: field(1, varint: end))
    }

    static func field(_ number: UInt64, varint value: UInt64) -> Data {
        encodeVarint((number << 3) | 0) + encodeVarint(value)
    }

    static func field(_ number: UInt64, string: String) -> Data {
        let bytes = Data(string.utf8)
        return encodeVarint((number << 3) | 2) + encodeVarint(UInt64(bytes.count)) + bytes
    }

    static func field(_ number: UInt64, message: Data) -> Data {
        encodeVarint((number << 3) | 2) + encodeVarint(UInt64(message.count)) + message
    }

    static func encodeVarint(_ value: UInt64) -> Data {
        var n = value
        var out = Data()
        while n >= 0x80 {
            out.append(UInt8(n & 0x7F) | 0x80)
            n >>= 7
        }
        out.append(UInt8(n))
        return out
    }
}
