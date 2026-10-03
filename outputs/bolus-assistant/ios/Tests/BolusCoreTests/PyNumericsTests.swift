import XCTest
@testable import BolusCore

final class PyNumericsTests: XCTestCase {
    private func dec(_ text: String) -> PyDecimal { PyDecimal(string: text)! }

    func testDecimalFromDoubleUsesShortestRepr() {
        XCTAssertEqual(PyDecimal(0.1)!, dec("0.1"))
        XCTAssertEqual(PyDecimal(10.2)!, dec("10.2"))
        XCTAssertEqual(PyDecimal(1.0 / 3.0)!, dec("0.3333333333333333"))
        XCTAssertEqual(PyDecimal(1e16)!, dec("1E+16"))
        XCTAssertEqual(PyDecimal(1e-5)!, dec("0.00001"))
        XCTAssertNil(PyDecimal(Double.nan))
        XCTAssertNil(PyDecimal(Double.infinity))
    }

    func testDivisionRoundsToTwentyEightDigitsHalfEven() {
        XCTAssertEqual((dec("1") / dec("3")).description, "3333333333333333333333333333E-28")
        XCTAssertEqual((dec("2") / dec("3")).description, "6666666666666666666666666667E-28")
        XCTAssertEqual((dec("62") / dec("10")).doubleValue, 6.2)
        XCTAssertEqual((dec("62.0") / dec("10.0")).description, "62E-1")
        XCTAssertEqual((dec("10.2") - dec("6")) / dec("2"), dec("2.1"))
    }

    func testAdditionAndCancellation() {
        let third = dec("10") / dec("3")
        let twoThirds = dec("2") / dec("3")
        XCTAssertEqual((third + twoThirds).doubleValue, 4.0)
        let zero = dec("1.5") - dec("1.50")
        XCTAssertTrue(zero.isZero)
        XCTAssertFalse(zero.isNegative)
    }

    func testFloorAndMultiple() {
        XCTAssertEqual((dec("7.4") / dec("0.25")).floorToIntegral() * dec("0.25"), dec("7.25"))
        XCTAssertEqual(dec("-0.5").floorToIntegral(), dec("-1"))
        XCTAssertTrue(PyDecimal.isIntegralMultiple(dec("3.75"), of: dec("0.25")))
        XCTAssertFalse(PyDecimal.isIntegralMultiple(dec("3.5"), of: dec("1.0")))
        XCTAssertTrue(PyDecimal.isIntegralMultiple(dec("2.2"), of: dec("0.1")))
    }

    func testPythonRound() {
        XCTAssertEqual(PyFloat.round(2.675, 2), 2.67)
        XCTAssertEqual(PyFloat.round(0.125, 2), 0.12)
        XCTAssertEqual(PyFloat.round(0.375, 2), 0.38)
        XCTAssertEqual(PyFloat.round(6.125, 2), 6.12)
        XCTAssertEqual(PyFloat.round(7.0, 2), 7.0)
        XCTAssertEqual(PyFloat.round(26.450000000000003, 4), 26.45)
        XCTAssertEqual(PyFloat.round(-0.001, 2).sign, .minus)
        XCTAssertEqual(PyFloat.round(1e20, 2), 1e20)
    }

    func testCorrectlyRoundedDivision() {
        XCTAssertEqual(PyFloat.divide(BigUInt(1), BigUInt(3)), 1.0 / 3.0)
        XCTAssertEqual(PyFloat.divide(BigUInt(2), BigUInt(4)), 0.5)
        // 2^53 + 1 is a tie between two doubles: rounds to even.
        let big = (BigUInt(1) << 53) + BigUInt(1)
        XCTAssertEqual(PyFloat.divide(big, BigUInt(1)), 9007199254740992.0)
    }

    func testStatistics() {
        XCTAssertEqual(PyStatistics.mean([3, 5, 7, 13]), 7)
        XCTAssertEqual(PyStatistics.median([3, 5, 7, 13]), 6)
        XCTAssertEqual(PyStatistics.median([1, 3, 5]), 3)
        XCTAssertEqual(PyStatistics.pstdev([1.5, 2.5, 2.5, 2.75, 3.25, 4.75]), 0.986893273527251)
        XCTAssertEqual(PyStatistics.pstdev([5.5]), 0)
        XCTAssertNil(PyStatistics.mean([]))
        XCTAssertNil(PyStatistics.pstdev([]))
    }

    func testBigUIntBasics() {
        let a = BigUInt(decimalDigits: "123456789012345678901234567890")!
        XCTAssertEqual(a.description, "123456789012345678901234567890")
        let b = BigUInt(decimalDigits: "987654321")!
        let (q, r) = a.quotientAndRemainder(dividingBy: b * b)
        XCTAssertEqual(q * (b * b) + r, a)
        XCTAssertEqual(BigUInt(decimalDigits: "1000000000000000000000000")!.squareRootFloor().description, "1000000000000")
        XCTAssertEqual(BigUInt(99).squareRootFloor(), BigUInt(9))
        XCTAssertEqual(BigUInt.gcd(BigUInt(48), BigUInt(180)), BigUInt(12))
        XCTAssertEqual((BigUInt(1) << 130) >> 129, BigUInt(2))
    }
}
