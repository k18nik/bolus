import Foundation

/// One time-of-day period of the therapy profile. Units: ICR g/U, ISF mmol/L per U,
/// target and correction threshold mmol/L. Keys match the reference backend JSON.
public struct TherapySegment: Codable, Equatable, Hashable, Sendable {
    public var startTime: String
    public var endTime: String
    public var icr: Double
    public var isf: Double
    public var target: Double
    public var correctAbove: Double

    public init(startTime: String, endTime: String, icr: Double, isf: Double, target: Double, correctAbove: Double) {
        self.startTime = startTime
        self.endTime = endTime
        self.icr = icr
        self.isf = isf
        self.target = target
        self.correctAbove = correctAbove
    }

    enum CodingKeys: String, CodingKey {
        case startTime = "start_time", endTime = "end_time", icr, isf, target, correctAbove = "correct_above"
    }
}

public enum TherapySegments {
    /// `select_segment`: exactly one segment must contain `localTime` ("HH:MM").
    public static func select(_ segments: [TherapySegment], localTime: String) throws -> TherapySegment {
        let matches = segments.filter { $0.startTime <= localTime && localTime < $0.endTime }
        guard matches.count == 1 else { throw BolusError.validation("Профиль терапии не покрывает текущее время без пересечений") }
        return matches[0]
    }

    static func isStartTime(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard value.count == 5, parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              parts[0].allSatisfy(\.isASCII), parts[1].allSatisfy(\.isASCII) else { return false }
        return (0...23).contains(h) && (0...59).contains(m)
    }

    static func isEndTime(_ value: String) -> Bool { value == "24:00" || isStartTime(value) }

    /// Port of `Segment` + `ProfileInput.coverage` validation. Returns sorted segments.
    public static func validated(_ segments: [TherapySegment]) throws -> [TherapySegment] {
        guard (1...24).contains(segments.count) else { throw BolusError.validation("Укажите от 1 до 24 периодов профиля") }
        for segment in segments {
            guard isStartTime(segment.startTime), isEndTime(segment.endTime) else {
                throw BolusError.validation("Время периода указывается как ЧЧ:ММ")
            }
            guard [segment.icr, segment.isf, segment.target, segment.correctAbove].allSatisfy(\.isFinite) else {
                throw BolusError.validation("Проверьте числовые значения профиля")
            }
            guard segment.icr > 0, segment.icr <= 200 else { throw BolusError.validation("ICR должен быть больше 0 и не больше 200 г/ЕД") }
            guard segment.isf > 0, segment.isf <= 30 else { throw BolusError.validation("ISF должен быть больше 0 и не больше 30 ммоль/л на ЕД") }
            guard segment.target >= 3.9, segment.target <= 15 else { throw BolusError.validation("Цель должна быть от 3,9 до 15 ммоль/л") }
            guard segment.correctAbove >= 3.9, segment.correctAbove <= 30 else { throw BolusError.validation("Порог коррекции должен быть от 3,9 до 30 ммоль/л") }
            guard segment.endTime > segment.startTime, segment.correctAbove >= segment.target else {
                throw BolusError.validation("Проверьте время и порог коррекции")
            }
        }
        let ordered = segments.sorted { $0.startTime < $1.startTime }
        let contiguous = zip(ordered, ordered.dropFirst()).allSatisfy { $0.endTime == $1.startTime }
        guard ordered.first?.startTime == "00:00", ordered.last?.endTime == "24:00", contiguous else {
            throw BolusError.validation("Профиль должен покрывать все 24 часа без пропусков")
        }
        return ordered
    }
}
