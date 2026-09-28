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
}
