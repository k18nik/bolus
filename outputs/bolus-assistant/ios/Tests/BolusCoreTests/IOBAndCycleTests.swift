import XCTest
@testable import BolusCore

/// Port of `backend/tests/test_iob_analytics.py` (IOB and cycle parts).
final class IOBAndCycleTests: XCTestCase {
    let at = referenceInstant

    func testModelVersion() {
        XCTAssertEqual(IOBEngine.modelVersion, "linear-remaining-v1.0.0")
    }

    func testLinearBoundaries() throws {
        let model = LinearActionModel()
        XCTAssertEqual(try model.remaining(elapsedHours: 0, diaHours: 4), 1)
        XCTAssertEqual(try model.remaining(elapsedHours: 2, diaHours: 4), 0.5)
        XCTAssertEqual(try model.remaining(elapsedHours: 4, diaHours: 4), 0)
        XCTAssertEqual(try model.remaining(elapsedHours: 8, diaHours: 4), 0)
        XCTAssertEqual(try model.remaining(elapsedHours: -1, diaHours: 4), 0)
        XCTAssertThrowsError(try model.remaining(elapsedHours: 0, diaHours: 0))
        XCTAssertThrowsError(try model.remaining(elapsedHours: .nan, diaHours: 4))
        XCTAssertThrowsError(try model.remaining(elapsedHours: 1, diaHours: 8.5))
    }

    func testActualOnlyBasalExcluded() throws {
        let doses = [
            AdministeredDose(units: 4, administeredAt: at.addingTimeInterval(-2 * 3600), diaHours: 4),
            AdministeredDose(units: 2, administeredAt: at.addingTimeInterval(-3600), diaHours: 4),
            AdministeredDose(units: 20, administeredAt: at, diaHours: 4, insulinType: .basal),
        ]
        XCTAssertEqual(try IOBEngine.calculate(doses, at: at), 3.5)
        XCTAssertEqual(try IOBEngine.calculate([], at: at), 0)
        XCTAssertThrowsError(try IOBEngine.calculate([AdministeredDose(units: -1, administeredAt: at, diaHours: 4)], at: at))
    }

    func testHistoricalDoseKeepsItsOwnDIA() throws {
        // Same elapsed time, different DIA saved at administration time.
        let early = AdministeredDose(units: 4, administeredAt: at.addingTimeInterval(-3 * 3600), diaHours: 3)
        let later = AdministeredDose(units: 4, administeredAt: at.addingTimeInterval(-3 * 3600), diaHours: 6)
        XCTAssertEqual(try IOBEngine.calculate([early], at: at), 0)
        XCTAssertEqual(try IOBEngine.calculate([later], at: at), 2)
    }

    func testBoundsAndMonotonicity() throws {
        var generator = SeededGenerator(seed: 7)
        let model = LinearActionModel()
        for _ in 0..<2000 {
            let elapsed = Double.random(in: 0...20, using: &generator)
            let dia = Double.random(in: 2...8, using: &generator)
            let units = Double.random(in: 0...100, using: &generator)
            let value = try model.remaining(elapsedHours: elapsed, diaHours: dia) * units
            XCTAssertTrue(value >= 0 && value <= units)
            XCTAssertLessThanOrEqual(try model.remaining(elapsedHours: elapsed + 0.1, diaHours: dia),
                                     try model.remaining(elapsedHours: elapsed, diaHours: dia))
        }
    }

    func testCycleNoRollover() {
        let start = LocalDate(date: at, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(CycleEngine.status(start: start, length: 28, today: start).phase, .menstrual)
        XCTAssertEqual(CycleEngine.status(start: start, length: 28, today: start.adding(days: 17)).phase, .earlyLuteal)
        XCTAssertEqual(CycleEngine.status(start: start, length: 28, today: start.adding(days: 24)).phase, .lateLuteal)
        XCTAssertEqual(CycleEngine.status(start: start, length: 28, today: start.adding(days: 30)).phase, .unknown)
    }

    func testCycleAllPhasesAndActualOvulation() {
        let start = LocalDate(iso: "2026-09-01")!
        let phases = (1...28).map { CycleEngine.status(start: start, length: 28, today: start.adding(days: $0 - 1)).phase }
        XCTAssertEqual(Set(phases), Set(CyclePhase.allCases.filter { $0 != .unknown }))
        let status = CycleEngine.status(start: start, length: 28, today: start.adding(days: 9))
        XCTAssertEqual(status.predictedOvulationDate, LocalDate(iso: "2026-09-14"))
        XCTAssertTrue(status.estimated)
        let actual = CycleEngine.status(start: start, length: 28, today: start.adding(days: 9), actualOvulation: LocalDate(iso: "2026-09-11"))
        XCTAssertEqual(actual.phase, .ovulatory)
        XCTAssertFalse(actual.estimated)
        XCTAssertEqual(actual.label, "Предполагаемая овуляция")
    }

    func testTimeSupport() {
        XCTAssertEqual(ISODate.format(at), "2026-10-02T12:00:00+00:00")
        XCTAssertEqual(ISODate.format(date("2026-10-02T12:00:00.123456Z")), "2026-10-02T12:00:00.123456+00:00")
        XCTAssertEqual(ISODate.format(at, timeZone: TimeZone(identifier: "Europe/Moscow")!), "2026-10-02T15:00:00+03:00")
        XCTAssertEqual(date("2026-10-02T15:00:00+03:00"), at)
        XCTAssertEqual(date("2026-10-02 12:00:00Z"), at)
        XCTAssertNil(ISODate.parse("2026-10-02T12:00:00"))
        XCTAssertNil(ISODate.parse("garbage"))
        XCTAssertEqual(WallClock.hourMinute(at, timeZone: TimeZone(identifier: "Europe/Moscow")!), "15:00")
        XCTAssertEqual(LocalDate(iso: "2024-02-29")?.adding(days: 1).description, "2024-03-01")
        XCTAssertNil(LocalDate(iso: "2026-02-29"))
        XCTAssertEqual(LocalDate(iso: "2026-10-05")?.weekdayMondayFirst, 0)
        XCTAssertEqual(LocalDate(iso: "2026-10-02")!.startOfDay(in: TimeZone(identifier: "Europe/Moscow")!), date("2026-10-01T21:00:00Z"))
        XCTAssertEqual(Micros.seconds(from: date("2026-10-02T11:59:59.000001Z"), to: at), 0.999999)
    }
}
