import Foundation

/// Microsecond timestamps.
///
/// Python `datetime` has exact microsecond resolution and `timedelta.total_seconds()`
/// is `microseconds / 10**6`. Converting `Date` to integer microseconds first makes
/// elapsed-time arithmetic identical to the reference implementation.
public enum Micros {
    /// Microseconds between 1970-01-01 and 2001-01-01 (Foundation reference date).
    static let referenceOffset: Int64 = 978_307_200_000_000

    public static func from(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSinceReferenceDate * 1_000_000).rounded()) + referenceOffset
    }

    public static func date(_ micros: Int64) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(micros - referenceOffset) / 1_000_000)
    }

    static func floorDivide(_ a: Int64, _ b: Int64) -> Int64 {
        let quotient = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? quotient - 1 : quotient
    }

    /// `(a - b).total_seconds()` in Python.
    public static func seconds(from b: Date, to a: Date) -> Double {
        Double(from(a) - from(b)) / 1_000_000
    }
}

/// ISO 8601 parsing/formatting compatible with Python `datetime.fromisoformat` /
/// `isoformat()` for timezone-aware values. Implemented without formatters so the
/// result is identical on every platform.
public enum ISODate {
    /// Parses `YYYY-MM-DD[T ]HH:MM[:SS[.fraction]](Z|±HH[:MM]|±HHMM)`.
    /// Naive values (without offset) are rejected, like comparing naive and aware
    /// datetimes is rejected in the reference implementation.
    public static func parse(_ text: String) -> Date? {
        let chars = Array(text.trimmingCharacters(in: .whitespaces).utf8)
        var index = 0
        func number(_ count: Int) -> Int? {
            guard index + count <= chars.count else { return nil }
            var value = 0
            for offset in 0..<count {
                let c = chars[index + offset]
                guard c >= 48, c <= 57 else { return nil }
                value = value * 10 + Int(c - 48)
            }
            index += count
            return value
        }
        func expect(_ byte: UInt8) -> Bool {
            guard index < chars.count, chars[index] == byte else { return false }
            index += 1
            return true
        }
        guard let year = number(4), expect(45), let month = number(2), expect(45), let day = number(2),
              let date = LocalDate(year: year, month: month, day: day) else { return nil }
        guard index < chars.count, chars[index] == 84 || chars[index] == 116 || chars[index] == 32 else { return nil }
        index += 1
        guard let hour = number(2), hour < 24, expect(58), let minute = number(2), minute < 60 else { return nil }
        var second = 0
        var micros = 0
        if expect(58) {
            guard let value = number(2), value < 60 else { return nil }
            second = value
            if index < chars.count, chars[index] == 46 || chars[index] == 44 {
                index += 1
                var digits = 0
                while index < chars.count, chars[index] >= 48, chars[index] <= 57 {
                    if digits < 6 { micros = micros * 10 + Int(chars[index] - 48) }
                    digits += 1
                    index += 1
                }
                guard digits > 0 else { return nil }
                for _ in min(digits, 6)..<6 { micros *= 10 }
            }
        }
        guard index < chars.count else { return nil }
        var offsetSeconds = 0
        if chars[index] == 90 || chars[index] == 122 {
            index += 1
        } else if chars[index] == 43 || chars[index] == 45 {
            let sign = chars[index] == 45 ? -1 : 1
            index += 1
            guard let hours = number(2) else { return nil }
            var minutes = 0
            if index < chars.count {
                _ = expect(58)
                guard let value = number(2) else { return nil }
                minutes = value
            }
            guard hours < 24, minutes < 60 else { return nil }
            offsetSeconds = sign * (hours * 3600 + minutes * 60)
        } else {
            return nil
        }
        guard index == chars.count else { return nil }
        let seconds = Int64(date.daysSinceEpoch) * 86_400 + Int64(hour * 3600 + minute * 60 + second) - Int64(offsetSeconds)
        return Micros.date(seconds * 1_000_000 + Int64(micros))
    }

    /// Python `dt.astimezone(tz).isoformat()`; UTC by default (`+00:00`).
    public static func format(_ date: Date, timeZone: TimeZone = TimeZone(identifier: "UTC")!) -> String {
        let micros = Micros.from(date)
        let offset = timeZone.secondsFromGMT(for: date)
        let local = micros + Int64(offset) * 1_000_000
        var seconds = local / 1_000_000
        var fraction = local % 1_000_000
        if fraction < 0 { fraction += 1_000_000; seconds -= 1 }
        var days = seconds / 86_400
        var secondOfDay = seconds % 86_400
        if secondOfDay < 0 { secondOfDay += 86_400; days -= 1 }
        let day = LocalDate(daysSinceEpoch: Int(days))
        let hour = Int(secondOfDay / 3600), minute = Int(secondOfDay % 3600 / 60), second = Int(secondOfDay % 60)
        var text = day.description + "T" + pad(hour) + ":" + pad(minute) + ":" + pad(second)
        if fraction != 0 { text += "." + String(format: "%06d", Int(fraction)) }
        let sign = offset < 0 ? "-" : "+"
        let absolute = abs(offset)
        text += sign + pad(absolute / 3600) + ":" + pad(absolute % 3600 / 60)
        return text
    }

    private static func pad(_ value: Int) -> String { value < 10 ? "0" + String(value) : String(value) }
}

/// Calendar date without time zone (`datetime.date` in Python).
public struct LocalDate: Comparable, Hashable, Codable, CustomStringConvertible, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month), day >= 1,
              day <= LocalDate.daysInMonth(year: year, month: month) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(iso text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// Days since 1970-01-01 (Howard Hinnant's `days_from_civil`).
    public var daysSinceEpoch: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    public init(daysSinceEpoch days: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        year = yoe + era * 400 + (m <= 2 ? 1 : 0)
        month = m
        day = d
    }

    /// Calendar date of an instant in a time zone.
    public init(date: Date, timeZone: TimeZone) {
        let seconds = Micros.floorDivide(Micros.from(date), 1_000_000) + Int64(timeZone.secondsFromGMT(for: date))
        self.init(daysSinceEpoch: Int(Micros.floorDivide(seconds, 86_400)))
    }

    public static func today(in timeZone: TimeZone, now: Date = Date()) -> LocalDate {
        LocalDate(date: now, timeZone: timeZone)
    }

    public func adding(days: Int) -> LocalDate { LocalDate(daysSinceEpoch: daysSinceEpoch + days) }

    /// Number of days from `other` to `self` (`(self - other).days`).
    public func days(since other: LocalDate) -> Int { daysSinceEpoch - other.daysSinceEpoch }

    /// Local midnight in the zone (`datetime.combine(d, time.min, tz)`).
    public func startOfDay(in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day, hour: 0, minute: 0, second: 0)
        if let date = calendar.date(from: components) { return date }
        let utc = Micros.date(Int64(daysSinceEpoch) * 86_400_000_000)
        return utc.addingTimeInterval(-Double(timeZone.secondsFromGMT(for: utc)))
    }

    /// 0 = Monday … 6 = Sunday.
    public var weekdayMondayFirst: Int { ((daysSinceEpoch % 7) + 7 + 3) % 7 }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func < (a: LocalDate, b: LocalDate) -> Bool { a.daysSinceEpoch < b.daysSinceEpoch }

    public static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let value = LocalDate(iso: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(text)")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Local wall-clock helpers.
public enum WallClock {
    /// Python `dt.astimezone(tz).strftime('%H:%M')`.
    public static func hourMinute(_ date: Date, timeZone: TimeZone) -> String {
        let secondOfDay = secondsOfDay(date, timeZone: timeZone)
        return String(format: "%02d:%02d", Int(secondOfDay / 3600), Int(secondOfDay % 3600 / 60))
    }

    /// Local hour 0…23.
    public static func hour(_ date: Date, timeZone: TimeZone) -> Int {
        Int(secondsOfDay(date, timeZone: timeZone) / 3600)
    }

    static func secondsOfDay(_ date: Date, timeZone: TimeZone) -> Int64 {
        let seconds = Micros.floorDivide(Micros.from(date), 1_000_000) + Int64(timeZone.secondsFromGMT(for: date))
        return seconds - Micros.floorDivide(seconds, 86_400) * 86_400
    }
}
