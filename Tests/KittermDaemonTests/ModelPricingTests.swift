import Foundation
import XCTest

@testable import KittermDaemon

/// The price table names the day it was read (`ModelPricing.ratesReadOn`)
/// and the daemon warns once at start when that day is old. Every clock here
/// is injected relative to `ratesReadOn` itself, never `Date()`: a test tied
/// to today's date would turn red on day 91 with no code change, which is
/// exactly what `green-ci-again` ruled out.
final class ModelPricingTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!

    /// Midnight UTC of the read day, offset by whole days. `ratesReadOn`
    /// carries no time of day, so the offset is what makes "N days ago"
    /// exact instead of off by one depending on the hour.
    private func readDayPlus(_ days: Int) -> Date {
        let readNoon = Date(timeIntervalSince1970: Double(ModelPricing.ratesReadOn.number) * 86_400 + 43_200)
        return readNoon.addingTimeInterval(Double(days) * 86_400)
    }

    func testFreshAtExactlyTheBoundary() {
        // "More than 90 days" reads literally: day 90 itself is still fresh.
        XCTAssertEqual(ModelPricing.ageDays(asOf: readDayPlus(90), in: utc), 90)
        XCTAssertFalse(ModelPricing.isStale(asOf: readDayPlus(90), in: utc))
    }

    func testFreshOneDayInsideTheBoundary() {
        XCTAssertFalse(ModelPricing.isStale(asOf: readDayPlus(89), in: utc))
    }

    func testStaleOneDayPastTheBoundary() {
        XCTAssertEqual(ModelPricing.ageDays(asOf: readDayPlus(91), in: utc), 91)
        XCTAssertTrue(ModelPricing.isStale(asOf: readDayPlus(91), in: utc))
    }

    func testWarningLineIsNilWhenFresh() {
        XCTAssertNil(ModelPricing.staleWarningLine(asOf: readDayPlus(90), in: utc))
    }

    func testWarningLineNamesTheDayAndTheAge() {
        let line = ModelPricing.staleWarningLine(asOf: readDayPlus(91), in: utc)
        XCTAssertEqual(
            line,
            "warning: the price table in ModelPricing.swift was read \(ModelPricing.ratesReadOn), "
                + "91 days ago; the running-session estimate may drift from the bill "
                + "until the rates are read again\n"
        )
    }

    // MARK: rates of the models in use, as read from the pricing page

    func testFable52AndMythos52Rates() {
        let want = ModelPricing(input: 8, cacheWrite5m: 10, cacheWrite1h: 16, cacheRead: 0.2, output: 40)
        XCTAssertEqual(ModelPricing.rates(for: "claude-fable-5-2"), want)
        XCTAssertEqual(ModelPricing.rates(for: "claude-mythos-5-2"), want)
    }

    func testOpus55Rates() {
        let want = ModelPricing(input: 4, cacheWrite5m: 5, cacheWrite1h: 8, cacheRead: 0.2, output: 20)
        XCTAssertEqual(ModelPricing.rates(for: "claude-opus-5-5"), want)
    }

    func testSonnet55Rates() {
        let want = ModelPricing(input: 2, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.1, output: 10)
        XCTAssertEqual(ModelPricing.rates(for: "claude-sonnet-5-5"), want)
    }

    func testLongContextAndDatedIdsFindTheirRate() {
        let opus = ModelPricing.rates(for: "claude-opus-5-5")
        XCTAssertNotNil(opus)
        XCTAssertEqual(ModelPricing.rates(for: "claude-opus-5-5[1m]"), opus)
        XCTAssertEqual(ModelPricing.rates(for: "claude-opus-5-5-20261101"), opus)
    }

    func testAShorterKeyDoesNotSwallowALongerId() {
        // `opus-5` is a key; `opus-5-5` and `opus-5-9` must not fall back to it.
        XCTAssertNotEqual(ModelPricing.rates(for: "claude-opus-5-5"), ModelPricing.rates(for: "claude-opus-5"))
        XCTAssertNil(ModelPricing.rates(for: "claude-opus-5-9"))
    }

    func testHaiku55StaysUnpricedBecauseThePageTiersIt() {
        XCTAssertNil(ModelPricing.rates(for: "claude-haiku-5-5"))
    }
}
