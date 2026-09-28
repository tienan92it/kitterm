import Foundation

/// The one price table in the daemon: Anthropic's first-party API rates per
/// model, in USD per million tokens, for the live estimate of a running
/// session (`TranscriptEstimate`).
///
/// ## Where a dollar comes from, and where it does not
///
/// Every bill the daemon reports is Claude Code's own `totalCostUSD`
/// (`TranscriptBill`), and the rollup apportions that bill and prices
/// nothing (`UsageRollup`). Only the estimate prices tokens, because a
/// running session has no bill yet, and the page marks that figure `~`.
/// Nothing else reads this table; a second table would be a second answer
/// to the same question.
///
/// The rates are the model pricing table at
/// `platform.claude.com/docs/en/about-claude/pricing`, read on the day
/// `ratesReadOn` names below. Nothing checks the rates themselves against
/// the page again; `isStale` only says when the day is old enough that a
/// human should.
/// Long context is standard pricing on every model here, so the `[1m]`
/// tier Claude Code names in a bill's `modelUsage` prices as its family;
/// an assistant line names the bare id, `claude-opus-5`, either way. A
/// cache write is priced by its TTL: `usage.cache_creation` splits the
/// tokens into `ephemeral_5m_input_tokens` and `ephemeral_1h_input_tokens`,
/// and Claude Code writes the hour kind, at twice the base rate.
public struct ModelPricing: Equatable, Sendable {
    /// USD per million tokens.
    public var input: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    public var cacheRead: Double
    public var output: Double

    /// Keyed by the id less the `claude-` prefix, a `[1m]` suffix and a
    /// trailing date, the way `ModelName` reads an id.
    static let table: [String: ModelPricing] = [
        "fable-5-1": ModelPricing(input: 10, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 0.25, output: 50),
        "mythos-5-1": ModelPricing(input: 10, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 0.25, output: 50),
        "fable-5": ModelPricing(input: 10, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 1, output: 50),
        "mythos-5": ModelPricing(input: 10, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 1, output: 50),
        "opus-5": ModelPricing(input: 5, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5, output: 25),
        "opus-4-8": ModelPricing(input: 5, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5, output: 25),
        "opus-4-7": ModelPricing(input: 5, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5, output: 25),
        "opus-4-6": ModelPricing(input: 5, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5, output: 25),
        "opus-4-5": ModelPricing(input: 5, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.5, output: 25),
        "opus-4-1": ModelPricing(input: 15, cacheWrite5m: 18.75, cacheWrite1h: 30, cacheRead: 1.5, output: 75),
        "opus-4": ModelPricing(input: 15, cacheWrite5m: 18.75, cacheWrite1h: 30, cacheRead: 1.5, output: 75),
        "sonnet-5": ModelPricing(input: 2, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.2, output: 10),
        "sonnet-4-6": ModelPricing(input: 3, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.3, output: 15),
        "sonnet-4-5": ModelPricing(input: 3, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.3, output: 15),
        "sonnet-4": ModelPricing(input: 3, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.3, output: 15),
        "haiku-4-5": ModelPricing(input: 1, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.1, output: 5),
        "haiku-3-5": ModelPricing(input: 0.8, cacheWrite5m: 1, cacheWrite1h: 1.6, cacheRead: 0.08, output: 4),
    ]

    /// The rates for a model id as a transcript writes it, or nil for an id
    /// the table does not know: the tokens are then counted and the dollars
    /// are not, never guessed from a neighbour.
    public static func rates(for id: String) -> ModelPricing? {
        guard id.hasPrefix(ModelName.prefix) else { return nil }
        var rest = String(id.dropFirst(ModelName.prefix.count))
        if rest.hasSuffix(ModelName.longContextSuffix) {
            rest = String(rest.dropLast(ModelName.longContextSuffix.count))
        }
        var parts = rest.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber), parts.count > 1 {
            parts.removeLast()
        }
        return table[parts.joined(separator: "-")]
    }

    /// The dollars for one model's tokens at these rates.
    public func cost(
        input: Int, cacheWrite5m: Int, cacheWrite1h: Int, cacheRead: Int, output: Int
    ) -> Double {
        (Double(input) * self.input
            + Double(cacheWrite5m) * self.cacheWrite5m
            + Double(cacheWrite1h) * self.cacheWrite1h
            + Double(cacheRead) * self.cacheRead
            + Double(output) * self.output) / 1_000_000
    }

    /// The day the rates above were read from `platform.claude.com`. The
    /// one place the date is a literal; every sentence about it, in this
    /// file or in `AGENTS.md`, names this value instead of repeating it.
    public static let ratesReadOn = DayKey("2026-09-20")!

    /// How many days a read table is trusted before a stale table should be
    /// read again. Chosen with the human on 2026-09-28; not a measurement.
    public static let staleAfterDays = 90

    /// Whole days between `ratesReadOn` and `now`, in `zone`. Pure: the
    /// daemon passes its own clock in, a test passes whatever it likes.
    public static func ageDays(asOf now: Date, in zone: TimeZone = TimeZone(identifier: "UTC")!) -> Int {
        DayKey(now, in: zone).number - ratesReadOn.number
    }

    /// True once the table is more than `staleAfterDays` old — day 90 itself
    /// is still fresh, day 91 is stale, matching "more than 90 days" read
    /// literally.
    public static func isStale(asOf now: Date, in zone: TimeZone = TimeZone(identifier: "UTC")!) -> Bool {
        ageDays(asOf: now, in: zone) > staleAfterDays
    }

    /// The one `server.log` line a stale table gets at daemon start, or nil
    /// when the table is fresh. Nothing on the output path calls this; a
    /// per-request check would repeat the same fact on every estimate.
    public static func staleWarningLine(asOf now: Date, in zone: TimeZone = TimeZone(identifier: "UTC")!) -> String? {
        guard isStale(asOf: now, in: zone) else { return nil }
        let days = ageDays(asOf: now, in: zone)
        return "warning: the price table in ModelPricing.swift was read \(ratesReadOn), "
            + "\(days) days ago; the running-session estimate may drift from the bill "
            + "until the rates are read again\n"
    }
}
