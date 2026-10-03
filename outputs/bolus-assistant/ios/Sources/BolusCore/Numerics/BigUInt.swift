import Foundation

/// Minimal arbitrary-precision unsigned integer.
///
/// It exists only to reproduce the exact arithmetic of the Python reference
/// implementation (`decimal.Decimal`, `fractions.Fraction`, `statistics`).
/// Little-endian 64-bit limbs without leading zero limbs; zero has no limbs.
public struct BigUInt: Comparable, Hashable, CustomStringConvertible, Sendable {
    public private(set) var limbs: [UInt64]

    public init() { limbs = [] }

    public init(_ value: UInt64) { limbs = value == 0 ? [] : [value] }

    public init(_ value: Int) {
        precondition(value >= 0, "BigUInt cannot represent negative values")
        self.init(UInt64(value))
    }

    init(limbs: [UInt64]) {
        self.limbs = limbs
        while let last = self.limbs.last, last == 0 { self.limbs.removeLast() }
    }

    /// Parses a non-empty string of ASCII decimal digits.
    public init?(decimalDigits text: Substring) {
        guard !text.isEmpty else { return nil }
        var result = BigUInt()
        var chunk: UInt64 = 0
        var chunkDigits = 0
        for scalar in text.unicodeScalars {
            guard scalar.value >= 48, scalar.value <= 57 else { return nil }
            chunk = chunk * 10 + UInt64(scalar.value - 48)
            chunkDigits += 1
            if chunkDigits == 18 {
                result = result.multipliedBySmall(1_000_000_000_000_000_000).addingSmall(chunk)
                chunk = 0
                chunkDigits = 0
            }
        }
        if chunkDigits > 0 {
            var scale: UInt64 = 1
            for _ in 0..<chunkDigits { scale *= 10 }
            result = result.multipliedBySmall(scale).addingSmall(chunk)
        }
        self = result
    }

    public var isZero: Bool { limbs.isEmpty }
    public var isOdd: Bool { (limbs.first ?? 0) & 1 == 1 }

    /// Python `int.bit_length()`.
    public var bitWidth: Int {
        guard let last = limbs.last else { return 0 }
        return (limbs.count - 1) * 64 + (64 - last.leadingZeroBitCount)
    }

    public var description: String {
        if isZero { return "0" }
        var parts: [UInt64] = []
        var value = self
        let base: UInt64 = 10_000_000_000_000_000_000
        while !value.isZero {
            let (q, r) = value.quotientAndRemainder(dividingBySmall: base)
            parts.append(r)
            value = q
        }
        var text = String(parts.removeLast())
        for part in parts.reversed() {
            let digits = String(part)
            text += String(repeating: "0", count: 19 - digits.count) + digits
        }
        return text
    }

    /// Number of decimal digits (0 has one digit, like Python `len(str(0))`).
    public var decimalDigitCount: Int { description.count }

    /// Exact conversion when the value fits into 53 bits, otherwise correctly rounded.
    public var doubleValue: Double { PyFloat.divide(self, BigUInt(1)) }

    // MARK: Comparison

    public static func < (a: BigUInt, b: BigUInt) -> Bool {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count }
        var index = a.limbs.count - 1
        while index >= 0 {
            if a.limbs[index] != b.limbs[index] { return a.limbs[index] < b.limbs[index] }
            index -= 1
        }
        return false
    }

    // MARK: Arithmetic

    public static func + (a: BigUInt, b: BigUInt) -> BigUInt {
        let count = max(a.limbs.count, b.limbs.count)
        var result: [UInt64] = []
        result.reserveCapacity(count + 1)
        var carry: UInt64 = 0
        for index in 0..<count {
            let x = index < a.limbs.count ? a.limbs[index] : 0
            let y = index < b.limbs.count ? b.limbs[index] : 0
            let (s1, o1) = x.addingReportingOverflow(y)
            let (s2, o2) = s1.addingReportingOverflow(carry)
            result.append(s2)
            carry = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        if carry > 0 { result.append(carry) }
        return BigUInt(limbs: result)
    }

    /// Requires `a >= b`.
    public static func - (a: BigUInt, b: BigUInt) -> BigUInt {
        precondition(a >= b, "BigUInt subtraction underflow")
        var result = a.limbs
        var borrow: UInt64 = 0
        for index in 0..<result.count {
            let y = index < b.limbs.count ? b.limbs[index] : 0
            let (d1, o1) = result[index].subtractingReportingOverflow(y)
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            result[index] = d2
            borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
        }
        return BigUInt(limbs: result)
    }

    public static func * (a: BigUInt, b: BigUInt) -> BigUInt {
        if a.isZero || b.isZero { return BigUInt() }
        var result = [UInt64](repeating: 0, count: a.limbs.count + b.limbs.count)
        for i in 0..<a.limbs.count {
            var carry: UInt64 = 0
            let x = a.limbs[i]
            for j in 0..<b.limbs.count {
                let (high, low) = x.multipliedFullWidth(by: b.limbs[j])
                let (s1, o1) = result[i + j].addingReportingOverflow(low)
                let (s2, o2) = s1.addingReportingOverflow(carry)
                result[i + j] = s2
                // x*y + r + c < 2^128, therefore the high word cannot overflow.
                carry = high &+ (o1 ? 1 : 0) &+ (o2 ? 1 : 0)
            }
            var k = i + b.limbs.count
            while carry > 0 {
                let (s, o) = result[k].addingReportingOverflow(carry)
                result[k] = s
                carry = o ? 1 : 0
                k += 1
            }
        }
        return BigUInt(limbs: result)
    }

    public static func / (a: BigUInt, b: BigUInt) -> BigUInt { a.quotientAndRemainder(dividingBy: b).quotient }
    public static func % (a: BigUInt, b: BigUInt) -> BigUInt { a.quotientAndRemainder(dividingBy: b).remainder }

    public static func << (a: BigUInt, shift: Int) -> BigUInt {
        precondition(shift >= 0)
        if a.isZero || shift == 0 { return a }
        let limbShift = shift / 64
        let bitShift = shift % 64
        var result = [UInt64](repeating: 0, count: limbShift)
        if bitShift == 0 {
            result.append(contentsOf: a.limbs)
        } else {
            var carry: UInt64 = 0
            for limb in a.limbs {
                result.append((limb << UInt64(bitShift)) | carry)
                carry = limb >> UInt64(64 - bitShift)
            }
            if carry > 0 { result.append(carry) }
        }
        return BigUInt(limbs: result)
    }

    public static func >> (a: BigUInt, shift: Int) -> BigUInt {
        precondition(shift >= 0)
        if shift == 0 { return a }
        let limbShift = shift / 64
        let bitShift = shift % 64
        guard limbShift < a.limbs.count else { return BigUInt() }
        var result: [UInt64] = []
        result.reserveCapacity(a.limbs.count - limbShift)
        for index in limbShift..<a.limbs.count {
            var value = a.limbs[index] >> UInt64(bitShift)
            if bitShift > 0, index + 1 < a.limbs.count {
                value |= a.limbs[index + 1] << UInt64(64 - bitShift)
            }
            result.append(value)
        }
        return BigUInt(limbs: result)
    }

    /// Low `count` bits of the value.
    public func lowBits(_ count: Int) -> BigUInt {
        if count <= 0 { return BigUInt() }
        let fullLimbs = count / 64
        let extraBits = count % 64
        if fullLimbs >= limbs.count { return self }
        var result = Array(limbs[0..<fullLimbs])
        if extraBits > 0 { result.append(limbs[fullLimbs] & ((UInt64(1) << UInt64(extraBits)) - 1)) }
        return BigUInt(limbs: result)
    }

    public func bit(_ index: Int) -> Bool {
        let limb = index / 64
        guard limb < limbs.count else { return false }
        return (limbs[limb] >> UInt64(index % 64)) & 1 == 1
    }

    func multipliedBySmall(_ factor: UInt64) -> BigUInt {
        if isZero || factor == 0 { return BigUInt() }
        var result: [UInt64] = []
        result.reserveCapacity(limbs.count + 1)
        var carry: UInt64 = 0
        for limb in limbs {
            let (high, low) = limb.multipliedFullWidth(by: factor)
            let (sum, overflow) = low.addingReportingOverflow(carry)
            result.append(sum)
            carry = high &+ (overflow ? 1 : 0)
        }
        if carry > 0 { result.append(carry) }
        return BigUInt(limbs: result)
    }

    func addingSmall(_ value: UInt64) -> BigUInt { self + BigUInt(value) }

    func quotientAndRemainder(dividingBySmall divisor: UInt64) -> (quotient: BigUInt, remainder: UInt64) {
        precondition(divisor != 0)
        var quotient = [UInt64](repeating: 0, count: limbs.count)
        var remainder: UInt64 = 0
        var index = limbs.count - 1
        while index >= 0 {
            let (q, r) = divisor.dividingFullWidth((high: remainder, low: limbs[index]))
            quotient[index] = q
            remainder = r
            index -= 1
        }
        return (BigUInt(limbs: quotient), remainder)
    }

    public func quotientAndRemainder(dividingBy divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        precondition(!divisor.isZero, "Division by zero")
        if self < divisor { return (BigUInt(), self) }
        if divisor.limbs.count == 1 {
            let (q, r) = quotientAndRemainder(dividingBySmall: divisor.limbs[0])
            return (q, BigUInt(r))
        }
        // Binary long division: operands here are at most a few thousand bits.
        var quotient = [UInt64](repeating: 0, count: limbs.count)
        var remainder = BigUInt()
        var index = bitWidth - 1
        while index >= 0 {
            remainder = remainder << 1
            if bit(index) { remainder = remainder + BigUInt(1) }
            if remainder >= divisor {
                remainder = remainder - divisor
                quotient[index / 64] |= UInt64(1) << UInt64(index % 64)
            }
            index -= 1
        }
        return (BigUInt(limbs: quotient), remainder)
    }

    /// Python `math.isqrt`: floor of the square root.
    public func squareRootFloor() -> BigUInt {
        if isZero { return self }
        var x = BigUInt(1) << ((bitWidth + 1) / 2)
        while true {
            let y = (x + self / x) >> 1
            if y >= x { return x }
            x = y
        }
    }

    public var trailingZeroBitCount: Int {
        for (index, limb) in limbs.enumerated() where limb != 0 {
            return index * 64 + limb.trailingZeroBitCount
        }
        return 0
    }

    /// Binary (Stein) greatest common divisor: shifts and subtractions only.
    public static func gcd(_ a: BigUInt, _ b: BigUInt) -> BigUInt {
        if a.isZero { return b }
        if b.isZero { return a }
        let common = min(a.trailingZeroBitCount, b.trailingZeroBitCount)
        var u = a >> a.trailingZeroBitCount
        var v = b
        repeat {
            v = v >> v.trailingZeroBitCount
            if u > v { swap(&u, &v) }
            v = v - u
        } while !v.isZero
        return u << common
    }

    private static let powersOfTen: [BigUInt] = {
        var values: [BigUInt] = [BigUInt(1)]
        for _ in 1...64 { values.append(values[values.count - 1].multipliedBySmall(10)) }
        return values
    }()

    public static func pow10(_ exponent: Int) -> BigUInt {
        precondition(exponent >= 0)
        if exponent < powersOfTen.count { return powersOfTen[exponent] }
        var result = powersOfTen[powersOfTen.count - 1]
        var remaining = exponent - (powersOfTen.count - 1)
        while remaining > 0 {
            let step = min(remaining, powersOfTen.count - 1)
            result = result * powersOfTen[step]
            remaining -= step
        }
        return result
    }
}
