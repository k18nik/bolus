import Foundation

/// Port of `backend/app/cycle/engine.py`.
/// Phases are an approximate guide; they never change insulin parameters or doses.
public enum CyclePhase: String, Codable, CaseIterable, Sendable {
    case menstrual
    case earlyFollicular = "early_follicular"
    case lateFollicular = "late_follicular"
    case ovulatory
    case earlyLuteal = "early_luteal"
    case midLuteal = "mid_luteal"
    case lateLuteal = "late_luteal"
    case unknown

    public var label: String {
        switch self {
        case .menstrual: return "Менструальная фаза"
        case .earlyFollicular: return "Ранняя фолликулярная фаза"
        case .lateFollicular: return "Поздняя фолликулярная фаза"
        case .ovulatory: return "Предполагаемая овуляция"
        case .earlyLuteal: return "Ранняя лютеиновая фаза"
        case .midLuteal: return "Средняя лютеиновая фаза"
        case .lateLuteal: return "Поздняя лютеиновая фаза"
        case .unknown: return "Фаза неизвестна"
        }
    }
}

public struct CycleStatus: Codable, Equatable, Sendable {
    public var day: Int
    public var phase: CyclePhase
    public var label: String
    public var estimated: Bool
    public var cycleLength: Int
    public var predictedOvulationDate: LocalDate

    enum CodingKeys: String, CodingKey {
        case day, phase, label, estimated, cycleLength = "cycle_length", predictedOvulationDate = "predicted_ovulation_date"
    }
}

public enum CycleEngine {
    public static let allowedLengths = 15...90
    public static let menstrualDays = 5

    public static func status(start: LocalDate, length: Int, today: LocalDate, actualOvulation: LocalDate? = nil) -> CycleStatus {
        let day = today.days(since: start) + 1
        let ovulation = actualOvulation.map { $0.days(since: start) + 1 } ?? length - 14
        var phase = CyclePhase.unknown
        if day >= 1 && day <= length {
            if day <= menstrualDays { phase = .menstrual }
            else if day < ovulation - 4 { phase = .earlyFollicular }
            else if day < ovulation - 1 { phase = .lateFollicular }
            else if day <= ovulation + 1 { phase = .ovulatory }
            else if day <= ovulation + 4 { phase = .earlyLuteal }
            else if day <= length - 5 { phase = .midLuteal }
            else { phase = .lateLuteal }
        }
        return CycleStatus(day: day, phase: phase, label: phase.label, estimated: actualOvulation == nil,
                           cycleLength: length, predictedOvulationDate: start.adding(days: ovulation - 1))
    }
}
