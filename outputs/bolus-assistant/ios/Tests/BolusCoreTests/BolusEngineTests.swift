import XCTest
@testable import BolusCore

/// Port of `backend/tests/test_bolus.py` and the device-step tests of
/// `backend/tests/test_personal_mode.py`.
final class BolusEngineTests: XCTestCase {
    func testAlgorithmVersionIsPreserved() {
        XCTAssertEqual(BolusEngine.algorithmVersion, "bolus-v1.1.0")
    }

    func testExamples() {
        let cases: [(BolusEngine.Input, Double)] = [
            (bolusInput(glucose: 6, carbs: 50, iob: 0), 5),
            (bolusInput(glucose: 10, carbs: 0, iob: 0), 2),
            (bolusInput(glucose: 10.2, carbs: 62, iob: 0.9), 7.4),
            (bolusInput(glucose: 5, carbs: 50, iob: 0), 4.5),
            (bolusInput(glucose: 6.9, carbs: 50, iob: 0), 5),
            (bolusInput(glucose: 7, carbs: 0, iob: 0), 0),
            (bolusInput(glucose: 10, carbs: 0, iob: 8), 0),
            (bolusInput(glucose: 6, carbs: 0, iob: 0), 0),
            (bolusInput(glucose: 6, carbs: 1, icr: 3, iob: 0), 0.3),
        ]
        for (input, expected) in cases {
            let result = BolusEngine.calculate(input, at: referenceInstant)
            XCTAssertEqual(result.calculationStatus, .ok, "\(input)")
            XCTAssertEqual(result.recommendedBolus, expected, "\(input)")
        }
    }

    func testDocumentedBreakdown() {
        let result = BolusEngine.calculate(bolusInput(), at: referenceInstant)
        XCTAssertEqual(result.mealBolus, 6.2)
        XCTAssertEqual(result.rawCorrectionBolus, 2.1)
        XCTAssertEqual(result.correctionBolus, 2.1)
        XCTAssertEqual(result.iobAdjustment, 0.9)
        XCTAssertEqual(result.unroundedBolus, 7.4)
        XCTAssertEqual(result.roundingIncrement, 0.1)
        XCTAssertEqual(result.roundingAdjustment, 0)
        XCTAssertEqual(result.warnings, [])
    }

    func testBlockedReasons() {
        let at = referenceInstant
        let cases: [(BolusEngine.Input, String)] = [
            (bolusInput(glucose: nil), "missing_glucose"),
            (bolusInput(glucose: 3.8), "extreme_glucose"),
            (bolusInput(glucose: 30.1), "extreme_glucose"),
            (bolusInput(glucose: .nan), "invalid_glucose"),
            (bolusInput(icr: 0), "invalid_icr"),
            (bolusInput(icr: -1), "invalid_icr"),
            (bolusInput(isf: 0), "invalid_isf"),
            (bolusInput(dia: 1), "invalid_dia"),
            (bolusInput(iob: -1), "unexpected_iob"),
            (bolusInput(iob: 201), "unexpected_iob"),
            (bolusInput(iob: .infinity), "invalid_numeric_input"),
            (bolusInput(carbs: -1), "invalid_carbs"),
            (bolusInput(maxBolus: 0), "invalid_max_bolus"),
            (bolusInput(target: 2), "invalid_target"),
            (bolusInput(unit: "mg/dL"), "unit_mismatch"),
            (bolusInput(measuredAt: at.addingTimeInterval(-16 * 60)), "stale_glucose"),
            (bolusInput(measuredAt: at.addingTimeInterval(2 * 60)), "future_glucose"),
            (bolusInput(measuredAt: nil), "missing_glucose_time"),
        ]
        for (input, reason) in cases {
            let result = BolusEngine.calculate(input, at: at)
            XCTAssertNil(result.recommendedBolus, reason)
            XCTAssertEqual(result.calculationStatus, .blocked, reason)
            XCTAssertTrue(result.warnings.contains(reason), "\(reason) not in \(result.warnings)")
        }
    }

    func testFreshnessBoundaries() {
        let at = referenceInstant
        XCTAssertEqual(BolusEngine.calculate(bolusInput(measuredAt: at.addingTimeInterval(-900)), at: at).calculationStatus, .ok)
        XCTAssertEqual(BolusEngine.calculate(bolusInput(measuredAt: date("2026-10-02T11:44:59.999999+00:00")), at: at).warnings, ["stale_glucose"])
        XCTAssertEqual(BolusEngine.calculate(bolusInput(measuredAt: at.addingTimeInterval(60)), at: at).calculationStatus, .ok)
        XCTAssertEqual(BolusEngine.calculate(bolusInput(measuredAt: date("2026-10-02T12:01:00.000001+00:00")), at: at).warnings, ["future_glucose"])
    }

    func testMaxBolusBlocksBeforeRoundingAndIsNeverReduced() {
        let result = BolusEngine.calculate(bolusInput(glucose: 6, carbs: 50.1, icr: 10, iob: 0, maxBolus: 5), at: referenceInstant)
        XCTAssertEqual(result.calculationStatus, .blocked)
        XCTAssertEqual(result.warnings, ["max_bolus_exceeded"])
        XCTAssertNil(result.recommendedBolus)
        XCTAssertEqual(result.unroundedBolus, 5.01)
    }

    func testBelowTargetReducesTotal() {
        let result = BolusEngine.calculate(bolusInput(glucose: 5, carbs: 50, iob: 0), at: referenceInstant)
        XCTAssertEqual(result.correctionBolus, -0.5)
        XCTAssertEqual(result.warnings, ["below_target"])
    }

    func testCorrectAboveThresholdIsExclusive() {
        let atThreshold = BolusEngine.calculate(bolusInput(glucose: 7, carbs: 0, iob: 0), at: referenceInstant)
        XCTAssertEqual(atThreshold.correctionBolus, 0)
        XCTAssertEqual(atThreshold.rawCorrectionBolus, 0.5)
        let above = BolusEngine.calculate(bolusInput(glucose: 7.1, carbs: 0, iob: 0), at: referenceInstant)
        XCTAssertEqual(above.recommendedBolus, 0.5)
    }

    func testDeviceSteps() {
        for (step, expected) in [(1.0, 3.0), (0.5, 3.5), (0.25, 3.75), (0.1, 3.7)] {
            let input = bolusInput(glucose: 6, carbs: 37.5, iob: 0, measuredAt: referenceInstant, bolusIncrement: step)
            XCTAssertEqual(BolusEngine.calculate(input, at: referenceInstant).recommendedBolus, expected, "step \(step)")
        }
        let personal = BolusEngine.calculate(bolusInput(glucose: 6, carbs: 35, iob: 0, bolusIncrement: 1), at: referenceInstant)
        XCTAssertEqual(personal.recommendedBolus, 3)
        XCTAssertEqual(personal.unroundedBolus, 3.5)
        XCTAssertEqual(personal.roundingIncrement, 1)
    }

    func testInvalidStepBlocks() {
        for step in [0, -1, 0.3, .nan, .infinity] as [Double] {
            let result = BolusEngine.calculate(bolusInput(glucose: 6, carbs: 35, iob: 0, bolusIncrement: step), at: referenceInstant)
            XCTAssertNil(result.recommendedBolus)
            XCTAssertTrue(result.warnings.contains("invalid_dose_step"))
        }
    }

    func testRoundingNeverExceedsRawAndIsDeliverable() {
        for step in InsulinCatalog.doseSteps {
            for tenths in stride(from: 0, through: 5000, by: 7) {
                let input = bolusInput(glucose: 6, carbs: Double(tenths) / 10, iob: 0, maxBolus: 50, bolusIncrement: step)
                let result = BolusEngine.calculate(input, at: referenceInstant)
                guard let dose = result.recommendedBolus, let raw = result.unroundedBolus else {
                    XCTFail("blocked for carbs \(Double(tenths) / 10)"); continue
                }
                XCTAssertTrue(InsulinCatalog.isDoseMultiple(dose, step: step) || dose == 0, "\(dose) step \(step)")
                XCTAssertTrue(dose >= 0 && dose <= raw && raw <= 50)
            }
        }
    }

    func testPropertiesOverRandomInputs() {
        var generator = SeededGenerator(seed: 350)
        for _ in 0..<2000 {
            let input = bolusInput(glucose: Double.random(in: 3.9...30, using: &generator),
                                   carbs: Double.random(in: 0...500, using: &generator),
                                   icr: Double.random(in: 0.1...100, using: &generator),
                                   isf: Double.random(in: 0.1...20, using: &generator),
                                   iob: Double.random(in: 0...200, using: &generator),
                                   maxBolus: Double.random(in: 0.1...50, using: &generator))
            let result = BolusEngine.calculate(input, at: referenceInstant)
            if result.calculationStatus == .ok {
                let dose = try! XCTUnwrap(result.recommendedBolus)
                XCTAssertTrue(dose.isFinite && dose >= 0 && dose <= input.maxBolus)
            } else {
                XCTAssertNil(result.recommendedBolus)
            }
        }
    }

    func testResultGuards() {
        XCTAssertEqual(SafetyLayer.validateResult(.nan, maxBolus: 10), ["invalid_result"])
        XCTAssertEqual(SafetyLayer.validateResult(-1, maxBolus: 10), ["negative_bolus"])
        XCTAssertEqual(SafetyLayer.validateResult(10.01, maxBolus: 10), ["max_bolus_exceeded"])
        XCTAssertEqual(SafetyLayer.validateResult(10, maxBolus: 10), [])
    }

    /// `backend/tests/golden/bolus_cases.json` evaluated with the same defaults.
    func testGoldenCases() throws {
        let cases = try XCTUnwrap(Fixture.json("golden_bolus_cases").arrayValue)
        XCTAssertGreaterThanOrEqual(cases.count, 100)
        for item in cases {
            let id = item.string("id") ?? "?"
            let values = try XCTUnwrap(item["input"])
            var input = bolusInput()
            if let v = values.double("glucose") { input.glucose = v }
            if let v = values.double("carbs") { input.carbs = v }
            if let v = values.double("icr") { input.icr = v }
            if let v = values.double("isf") { input.isf = v }
            if let v = values.double("iob") { input.iob = v }
            if let v = values.double("max_bolus") { input.maxBolus = v }
            if let v = values.double("target") { input.target = v }
            if let v = values.double("correct_above") { input.correctAbove = v }
            let result = BolusEngine.calculate(input, at: referenceInstant)
            XCTAssertEqual(result.calculationStatus.rawValue, item.string("expected_status"), id)
            XCTAssertEqual(result.recommendedBolus, item.double("expected_bolus"), id)
        }
    }

    func testSegments() throws {
        let segments = [
            TherapySegment(startTime: "00:00", endTime: "06:00", icr: 12, isf: 2.5, target: 6, correctAbove: 7),
            TherapySegment(startTime: "06:00", endTime: "24:00", icr: 8, isf: 2, target: 6, correctAbove: 7),
        ]
        XCTAssertEqual(try TherapySegments.select(segments, localTime: "05:59").icr, 12)
        XCTAssertEqual(try TherapySegments.select(segments, localTime: "06:00").icr, 8)
        XCTAssertEqual(try TherapySegments.select(segments, localTime: "23:59").isf, 2)
        XCTAssertThrowsError(try TherapySegments.select([], localTime: "08:00"))
        XCTAssertEqual(try TherapySegments.validated(segments.reversed()).map(\.startTime), ["00:00", "06:00"])
        var gap = segments
        gap[0].endTime = "05:00"
        XCTAssertThrowsError(try TherapySegments.validated(gap))
        var badThreshold = segments
        badThreshold[1].correctAbove = 5
        XCTAssertThrowsError(try TherapySegments.validated(badThreshold))
    }

    func testInsulinCatalog() throws {
        XCTAssertEqual(InsulinCatalog.identify("Фиасп®")?.id, "fiasp")
        XCTAssertEqual(InsulinCatalog.identify("fiasp penfill")?.id, "fiasp")
        XCTAssertEqual(InsulinCatalog.identify("Тресиба")?.type, .basal)
        XCTAssertNil(InsulinCatalog.identify("Хумалог"))
        XCTAssertThrowsError(try InsulinCatalog.checkType("Тресиба", .rapid)) { error in
            XCTAssertEqual(error.localizedDescription, "Тресиба: выберите базальный инсулин")
        }
        XCTAssertEqual(try InsulinCatalog.metadata("", .rapid).insulinID, "custom")
        XCTAssertEqual(try InsulinCatalog.metadata("Фиасп", .rapid).activeIngredient, "инсулин аспарт")
        XCTAssertTrue(InsulinCatalog.isDoseMultiple(3, step: 1))
        XCTAssertFalse(InsulinCatalog.isDoseMultiple(3.5, step: 1))
        XCTAssertTrue(InsulinCatalog.isDoseMultiple(2.2, step: 0.1))
        XCTAssertTrue(InsulinCatalog.isDoseMultiple(3.75, step: 0.25))
    }
}
