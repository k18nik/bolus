import Foundation

/// Exact binary value of a finite `Double`: `(-1)^negative * mantissa * 2^exponent`.
public struct BinaryRational: Sendable {
    public var negative: Bool
    public var mantissa: BigUInt
    public var exponent: Int

    public init(_ value: Double) {
        precondition(value.isFinite)
        negative = value.sign == .minus
        let bits = value.significandBitPattern
        let biased = Int(value.exponentBitPattern)
        if biased == 0 {
            mantissa = BigUInt(bits)
            exponent = -1074
        } else {
            mantissa = BigUInt(bits | (UInt64(1) << 52))
            exponent = biased - 1075
        }
    }
}

/// A number as Python typed it, where `int` versus `float` changes a result.
public enum PyNumber: Sendable, Equatable {
    case int(Int)
    case float(Double)
}

/// Python float semantics that are not plain IEEE operations.
public enum PyFloat {
    /// Python 3.12+ `sum()` of floats (the backend image runs Python 3.12): Neumaier
    /// compensated summation exactly as in CPython's `builtin_sum_impl`, with the
    /// compensation added once at the end and skipped when it is not finite.
    /// Whole numbers below 2^53 add exactly, so integer data matches Python's int path.
    public static func sum<S: Sequence>(_ values: S) -> Double where S.Element == Double {
        var total = 0.0
        var compensation = 0.0
        for x in values {
            let t = total + x
            if Swift.abs(total) >= Swift.abs(x) {
                compensation += (total - t) + x
            } else {
                compensation += (x - t) + total
            }
            total = t
        }
        if compensation != 0, compensation.isFinite { total += compensation }
        return total
    }

    /// `sum()` over a list that mixes Python `int` and `float`. CPython 3.12 adds leading
    /// ints exactly, converts at the first float and compensates only float additions;
    /// later ints are added plainly. Matters for `duration_minutes`, an `int` for manual
    /// activity and a `float` for Apple Health workouts.
    public static func sum(_ items: [PyNumber]) -> Double {
        var index = items.startIndex
        var integer = 0
        while index < items.endIndex, case .int(let value) = items[index] {
            integer += value
            index += 1
        }
        guard index < items.endIndex, case .float(let first) = items[index] else { return Double(integer) }
        var total = Double(integer) + first
        var compensation = 0.0
        for item in items[(index + 1)...] {
            switch item {
            case .float(let x):
                let t = total + x
                if Swift.abs(total) >= Swift.abs(x) {
                    compensation += (total - t) + x
                } else {
                    compensation += (x - t) + total
                }
                total = t
            case .int(let value):
                total += Double(value)
            }
        }
        if compensation != 0, compensation.isFinite { total += compensation }
        return total
    }

    /// Python `round(x, ndigits)` for floats: correctly rounded half-even on the exact
    /// binary value, then converted back with correctly rounded parsing.
    public static func round(_ value: Double, _ digits: Int) -> Double {
        precondition(digits >= 0)
        guard value.isFinite, value != 0 else { return value }
        let exact = BinaryRational(value)
        // Integral values (non-negative binary exponent) are unchanged.
        guard exact.exponent < 0 else { return value }
        let shift = -exact.exponent
        let scaled = exact.mantissa * BigUInt.pow10(digits)
        var quotient = scaled >> shift
        let remainder = scaled.lowBits(shift)
        let half = BigUInt(1) << (shift - 1)
        if remainder > half || (remainder == half && quotient.isOdd) {
            quotient = quotient + BigUInt(1)
        }
        if quotient.isZero { return exact.negative ? -0.0 : 0.0 }
        let text = (exact.negative ? "-" : "") + quotient.description + "e-" + String(digits)
        return Double(text) ?? .nan
    }

    /// Correctly rounded `numerator / denominator` (Python int true division).
    public static func divide(_ numerator: BigUInt, _ denominator: BigUInt, negative: Bool = false) -> Double {
        precondition(!denominator.isZero)
        if numerator.isZero { return negative ? -0.0 : 0.0 }
        // Produce a quotient with 55 or 56 significant bits, keep the remainder as sticky.
        let shift = 55 - (numerator.bitWidth - denominator.bitWidth)
        let (quotient, remainder): (BigUInt, BigUInt)
        if shift >= 0 {
            (quotient, remainder) = (numerator << shift).quotientAndRemainder(dividingBy: denominator)
        } else {
            (quotient, remainder) = numerator.quotientAndRemainder(dividingBy: denominator << -shift)
        }
        var extra = quotient.bitWidth - 53
        var significand = quotient >> extra
        let dropped = quotient.lowBits(extra)
        let half = BigUInt(1) << (extra - 1)
        if dropped > half || (dropped == half && (!remainder.isZero || significand.isOdd)) {
            significand = significand + BigUInt(1)
            if significand.bitWidth > 53 {
                significand = significand >> 1
                extra += 1
            }
        }
        // `significand < 2^53`, so the conversion and scaling are exact for normal results
        // (diary values never approach the subnormal or overflow range).
        let mantissa = Double(significand.limbs.first ?? 0)
        return Double(sign: negative ? .minus : .plus, exponent: extra - shift, significand: mantissa)
    }

    /// Exact signed sum of doubles as `(negative, numerator, denominator = 2^k)`.
    static func exactSum(_ values: [Double]) -> (negative: Bool, numerator: BigUInt, denominatorShift: Int) {
        guard !values.isEmpty else { return (false, BigUInt(), 0) }
        let parts = values.map(BinaryRational.init)
        let minimum = parts.map(\.exponent).min() ?? 0
        var positive = BigUInt()
        var negativeSum = BigUInt()
        for part in parts {
            let scaled = part.mantissa << (part.exponent - minimum)
            if part.negative { negativeSum = negativeSum + scaled } else { positive = positive + scaled }
        }
        let negative = negativeSum > positive
        let magnitude = negative ? negativeSum - positive : positive - negativeSum
        if minimum >= 0 { return (negative, magnitude << minimum, 0) }
        return (negative, magnitude, -minimum)
    }
}

/// `statistics.mean / median / pstdev` with the exact semantics of CPython 3.11+.
public enum PyStatistics {
    /// `statistics.mean` for floats: exact sum as a fraction, correctly rounded result.
    public static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sum = PyFloat.exactSum(values)
        let denominator = (BigUInt(1) << sum.denominatorShift) * BigUInt(values.count)
        return PyFloat.divide(sum.numerator, denominator, negative: sum.negative)
    }

    /// `statistics.median`: middle value or the float average of the two middle values.
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let count = sorted.count
        if count % 2 == 1 { return sorted[count / 2] }
        return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
    }

    /// `statistics.pstdev`: correctly rounded square root of the exact population variance.
    public static func pstdev(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let parts = values.map(BinaryRational.init)
        let minimum = parts.map(\.exponent).min() ?? 0
        let base = min(minimum, 0)
        // Scaled integers X_i = x_i * 2^-base (signs tracked separately).
        var sumPositive = BigUInt()
        var sumNegative = BigUInt()
        var sumSquares = BigUInt()
        for part in parts {
            let scaled = part.mantissa << (part.exponent - base)
            if part.negative { sumNegative = sumNegative + scaled } else { sumPositive = sumPositive + scaled }
            sumSquares = sumSquares + scaled * scaled
        }
        let sumMagnitude = sumPositive > sumNegative ? sumPositive - sumNegative : sumNegative - sumPositive
        let count = BigUInt(values.count)
        // mss = (n*Σx² - (Σx)²) / n² with the common 2^(2*base) scale.
        let numeratorScaled = count * sumSquares - sumMagnitude * sumMagnitude
        var numerator = numeratorScaled
        var denominator = (count * count) << (-2 * base)
        if numerator.isZero {
            denominator = BigUInt(1)
        } else {
            let divisor = BigUInt.gcd(numerator, denominator)
            numerator = numerator / divisor
            denominator = denominator / divisor
        }
        return floatSqrtOfFraction(numerator, denominator)
    }

    static let sqrtBitWidth = 2 * 53 + 3

    /// `statistics._integer_sqrt_of_frac_rto`.
    static func integerSqrtOfFractionRoundToOdd(_ n: BigUInt, _ m: BigUInt) -> BigUInt {
        let a = (n / m).squareRootFloor()
        return a * a * m != n ? (a.isOdd ? a : a + BigUInt(1)) : a
    }

    /// `statistics._float_sqrt_of_frac`.
    static func floatSqrtOfFraction(_ n: BigUInt, _ m: BigUInt) -> Double {
        let difference = n.bitWidth - m.bitWidth - sqrtBitWidth
        let q = floorDivide(difference, 2)
        if q >= 0 {
            let numerator = integerSqrtOfFractionRoundToOdd(n, m << (2 * q)) << q
            return PyFloat.divide(numerator, BigUInt(1))
        }
        let numerator = integerSqrtOfFractionRoundToOdd(n << (-2 * q), m)
        return PyFloat.divide(numerator, BigUInt(1) << -q)
    }

    /// Python floor division for integers.
    static func floorDivide(_ a: Int, _ b: Int) -> Int {
        let quotient = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? quotient - 1 : quotient
    }
}
