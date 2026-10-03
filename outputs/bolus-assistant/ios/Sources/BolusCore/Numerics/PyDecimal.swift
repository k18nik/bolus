import Foundation

/// Value-exact reproduction of Python's `decimal.Decimal` for finite numbers in the
/// default context (precision 28, ROUND_HALF_EVEN).
///
/// The reference bolus engine (`backend/app/bolus/engine.py`) converts every input
/// with `Decimal(str(value))` and computes in this context. Using the same semantics
/// guarantees that Swift results match Python bit for bit, including the floor
/// rounding to the device step.
public struct PyDecimal: Comparable, CustomStringConvertible, Sendable {
    public static let precision = 28

    public var isNegative: Bool
    public var coefficient: BigUInt
    public var exponent: Int

    public init(isNegative: Bool = false, coefficient: BigUInt, exponent: Int) {
        self.isNegative = isNegative
        self.coefficient = coefficient
        self.exponent = exponent
    }

    public static let zero = PyDecimal(coefficient: BigUInt(), exponent: 0)

    /// Python `Decimal(str(x))` for a finite `Double`.
    ///
    /// Swift's `description` and Python's `repr` both produce the shortest digit string
    /// that round-trips (choosing the closest one among equally short candidates).
    public init?(_ value: Double) {
        guard value.isFinite else { return nil }
        self.init(string: value.description)
    }

    /// Exact parsing of `[+-]digits[.digits][(e|E)[+-]digits]`, no rounding (like the
    /// `Decimal` constructor).
    public init?(string text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        var negative = false
        if rest.hasPrefix("-") { negative = true; rest = rest.dropFirst() } else if rest.hasPrefix("+") { rest = rest.dropFirst() }
        var exponentPart = 0
        if let marker = rest.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            guard let value = Int(rest[rest.index(after: marker)...]) else { return nil }
            exponentPart = value
            rest = rest[..<marker]
        }
        var integerPart = rest
        var fractionPart: Substring = ""
        if let dot = rest.firstIndex(of: ".") {
            integerPart = rest[..<dot]
            fractionPart = rest[rest.index(after: dot)...]
        }
        guard !(integerPart.isEmpty && fractionPart.isEmpty),
              let digits = BigUInt(decimalDigits: Substring(String(integerPart) + String(fractionPart))) else { return nil }
        self.init(isNegative: negative, coefficient: digits, exponent: exponentPart - fractionPart.count)
    }

    public var isZero: Bool { coefficient.isZero }

    /// Python `float(Decimal)`: `float(str(self))`, i.e. correctly rounded parsing.
    public var doubleValue: Double {
        let text = (isNegative ? "-" : "") + coefficient.description + "e" + String(exponent)
        return Double(text) ?? .nan
    }

    public var description: String {
        (isNegative ? "-" : "") + coefficient.description + (exponent == 0 ? "" : "E" + String(exponent))
    }

    public var negated: PyDecimal { PyDecimal(isNegative: !isNegative, coefficient: coefficient, exponent: exponent) }

    // MARK: Context rounding

    /// `Decimal._fix`: round to `precision` significant digits, ROUND_HALF_EVEN.
    static func fixed(negative: Bool, coefficient: BigUInt, exponent: Int) -> PyDecimal {
        let digits = coefficient.decimalDigitCount
        guard digits > precision else {
            return PyDecimal(isNegative: negative, coefficient: coefficient, exponent: exponent)
        }
        var drop = digits - precision
        let divisor = BigUInt.pow10(drop)
        var (quotient, remainder) = coefficient.quotientAndRemainder(dividingBy: divisor)
        let half = BigUInt.pow10(drop - 1) * BigUInt(5)
        if remainder > half || (remainder == half && quotient.isOdd) {
            quotient = quotient + BigUInt(1)
            if quotient.decimalDigitCount > precision {
                quotient = quotient / BigUInt(10)
                drop += 1
            }
        }
        return PyDecimal(isNegative: negative, coefficient: quotient, exponent: exponent + drop)
    }

    // MARK: Arithmetic (exact result, then context rounding)

    public static func + (a: PyDecimal, b: PyDecimal) -> PyDecimal {
        let exponent = min(a.exponent, b.exponent)
        let ca = a.coefficient * BigUInt.pow10(a.exponent - exponent)
        let cb = b.coefficient * BigUInt.pow10(b.exponent - exponent)
        if a.isNegative == b.isNegative {
            return fixed(negative: a.isNegative, coefficient: ca + cb, exponent: exponent)
        }
        if ca == cb {
            // An exact cancellation is +0 in every rounding mode except ROUND_FLOOR.
            return fixed(negative: false, coefficient: BigUInt(), exponent: exponent)
        }
        return ca > cb
            ? fixed(negative: a.isNegative, coefficient: ca - cb, exponent: exponent)
            : fixed(negative: b.isNegative, coefficient: cb - ca, exponent: exponent)
    }

    public static func - (a: PyDecimal, b: PyDecimal) -> PyDecimal { a + b.negated }

    public static func * (a: PyDecimal, b: PyDecimal) -> PyDecimal {
        fixed(negative: a.isNegative != b.isNegative, coefficient: a.coefficient * b.coefficient, exponent: a.exponent + b.exponent)
    }

    /// `Decimal.__truediv__` for finite, non-zero divisors.
    public static func / (a: PyDecimal, b: PyDecimal) -> PyDecimal {
        precondition(!b.isZero, "Decimal division by zero")
        let negative = a.isNegative != b.isNegative
        if a.isZero {
            return fixed(negative: negative, coefficient: BigUInt(), exponent: a.exponent - b.exponent)
        }
        let shift = b.coefficient.decimalDigitCount - a.coefficient.decimalDigitCount + precision + 1
        var exponent = a.exponent - b.exponent - shift
        var quotient: BigUInt
        let remainder: BigUInt
        if shift >= 0 {
            (quotient, remainder) = (a.coefficient * BigUInt.pow10(shift)).quotientAndRemainder(dividingBy: b.coefficient)
        } else {
            (quotient, remainder) = a.coefficient.quotientAndRemainder(dividingBy: b.coefficient * BigUInt.pow10(-shift))
        }
        if !remainder.isZero {
            // Inexact: make sure the sticky digit is non-zero so rounding is correct.
            if (quotient % BigUInt(5)).isZero { quotient = quotient + BigUInt(1) }
        } else {
            let ideal = a.exponent - b.exponent
            while exponent < ideal, (quotient % BigUInt(10)).isZero {
                quotient = quotient / BigUInt(10)
                exponent += 1
            }
        }
        return fixed(negative: negative, coefficient: quotient, exponent: exponent)
    }

    /// `to_integral_value(rounding=ROUND_FLOOR)` (exact, no context rounding).
    public func floorToIntegral() -> PyDecimal {
        guard exponent < 0 else { return self }
        let (quotient, remainder) = coefficient.quotientAndRemainder(dividingBy: BigUInt.pow10(-exponent))
        let rounded = isNegative && !remainder.isZero ? quotient + BigUInt(1) : quotient
        return PyDecimal(isNegative: isNegative, coefficient: rounded, exponent: 0)
    }

    /// Python `round(Decimal, places)`: quantize to `10^-places`, ROUND_HALF_EVEN.
    public func rounded(places: Int) -> PyDecimal {
        let target = -places
        guard exponent < target else { return self }
        let drop = target - exponent
        var (quotient, remainder) = coefficient.quotientAndRemainder(dividingBy: BigUInt.pow10(drop))
        let half = BigUInt.pow10(drop - 1) * BigUInt(5)
        if remainder > half || (remainder == half && quotient.isOdd) { quotient = quotient + BigUInt(1) }
        return PyDecimal(isNegative: isNegative, coefficient: quotient, exponent: target)
    }

    /// Python: `Decimal(str(a)) % Decimal(str(b)) == 0` for positive operands.
    public static func isIntegralMultiple(_ value: PyDecimal, of step: PyDecimal) -> Bool {
        guard !step.isZero else { return false }
        let exponent = min(value.exponent, step.exponent)
        let a = value.coefficient * BigUInt.pow10(value.exponent - exponent)
        let b = step.coefficient * BigUInt.pow10(step.exponent - exponent)
        return (a % b).isZero
    }

    // MARK: Exact comparison

    public static func == (a: PyDecimal, b: PyDecimal) -> Bool { compare(a, b) == 0 }
    public static func < (a: PyDecimal, b: PyDecimal) -> Bool { compare(a, b) < 0 }

    static func compare(_ a: PyDecimal, _ b: PyDecimal) -> Int {
        if a.isZero && b.isZero { return 0 }
        let aSign = a.isZero ? 0 : (a.isNegative ? -1 : 1)
        let bSign = b.isZero ? 0 : (b.isNegative ? -1 : 1)
        if aSign != bSign { return aSign < bSign ? -1 : 1 }
        let exponent = min(a.exponent, b.exponent)
        let ca = a.coefficient * BigUInt.pow10(a.exponent - exponent)
        let cb = b.coefficient * BigUInt.pow10(b.exponent - exponent)
        if ca == cb { return 0 }
        let magnitude = ca < cb ? -1 : 1
        return aSign < 0 ? -magnitude : magnitude
    }

    /// Python builtin `max(a, b)`: returns `a` unless `b > a`.
    public static func pyMax(_ a: PyDecimal, _ b: PyDecimal) -> PyDecimal { b > a ? b : a }
    /// Python builtin `min(a, b)`: returns `a` unless `b < a`.
    public static func pyMin(_ a: PyDecimal, _ b: PyDecimal) -> PyDecimal { b < a ? b : a }
}
