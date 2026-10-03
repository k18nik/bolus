import Foundation

/// Port of `backend/app/safety/validation.py`.
///
/// Any returned reason blocks the calculation. Exceeding `max_bolus` is never
/// "fixed" by lowering the dose: the result becomes `blocked`.
public enum SafetyLayer {
    public static let allowedSteps: [Double] = InsulinCatalog.doseSteps
    /// Measurement older than 15 minutes is stale.
    public static let maxGlucoseAgeSeconds: Double = 900
    /// Measurement more than 1 minute in the future is rejected.
    public static let maxFutureSkewSeconds: Double = 60

    public static func validateInputs(_ input: BolusEngine.Input, now: Date) -> [String] {
        let numeric = [input.carbs, input.icr, input.isf, input.target, input.correctAbove, input.dia, input.iob, input.maxBolus]
        if numeric.contains(where: { !$0.isFinite }) { return ["invalid_numeric_input"] }
        var errors: [String] = []
        if let glucose = input.glucose {
            if !glucose.isFinite { errors.append("invalid_glucose") }
            else if glucose < 3.9 || glucose > 30 { errors.append("extreme_glucose") }
        } else {
            errors.append("missing_glucose")
        }
        if input.unit != "mmol/L" { errors.append("unit_mismatch") }
        let step = input.bolusIncrement ?? 0.1
        if !step.isFinite || !allowedSteps.contains(step) { errors.append("invalid_dose_step") }
        if !(input.icr > 0 && input.icr <= 200) { errors.append("invalid_icr") }
        if !(input.isf > 0 && input.isf <= 30) { errors.append("invalid_isf") }
        if !(input.dia >= 2 && input.dia <= 8) { errors.append("invalid_dia") }
        if !(input.iob >= 0 && input.iob <= 200) { errors.append("unexpected_iob") }
        if !(input.carbs >= 0 && input.carbs <= 500) { errors.append("invalid_carbs") }
        if !(input.maxBolus > 0 && input.maxBolus <= 50) { errors.append("invalid_max_bolus") }
        if !(input.target >= 3.9 && input.target <= 15) || !(input.target <= input.correctAbove && input.correctAbove <= 30) {
            errors.append("invalid_target")
        }
        if let measuredAt = input.measuredAt {
            let age = Micros.seconds(from: measuredAt, to: now)
            if age > maxGlucoseAgeSeconds { errors.append("stale_glucose") }
            if age < -maxFutureSkewSeconds { errors.append("future_glucose") }
        } else {
            errors.append("missing_glucose_time")
        }
        return errors
    }

    public static func validateResult(_ recommendation: Double, maxBolus: Double) -> [String] {
        if !recommendation.isFinite { return ["invalid_result"] }
        if recommendation < 0 { return ["negative_bolus"] }
        if recommendation > maxBolus { return ["max_bolus_exceeded"] }
        return []
    }

    /// Human-readable explanations (from the web calculator).
    public static let messages: [String: String] = [
        "invalid_numeric_input": "Проверьте числовые параметры профиля и IOB.",
        "missing_glucose": "Введите актуальную глюкозу.",
        "invalid_glucose": "Проверьте значение глюкозы.",
        "extreme_glucose": "Глюкоза вне границ расчёта (3,9–30 ммоль/л). Следуйте вашему согласованному плану действий.",
        "unit_mismatch": "Проверьте единицы измерения.",
        "invalid_dose_step": "Проверьте шаг устройства в профиле.",
        "invalid_icr": "Проверьте ICR в профиле.",
        "invalid_isf": "Проверьте ISF в профиле.",
        "invalid_dia": "Проверьте DIA в профиле (2–8 ч).",
        "unexpected_iob": "IOB вне допустимых границ.",
        "invalid_carbs": "Углеводы должны быть от 0 до 500 г.",
        "invalid_max_bolus": "Проверьте максимальный болюс в профиле.",
        "invalid_target": "Проверьте цель и порог коррекции в профиле.",
        "stale_glucose": "Измерению больше 15 минут. Нужна свежая глюкоза.",
        "future_glucose": "Время измерения находится в будущем.",
        "missing_glucose_time": "Укажите время измерения глюкозы.",
        "invalid_result": "Расчёт дал некорректный результат.",
        "negative_bolus": "Расчёт дал отрицательный результат.",
        "max_bolus_exceeded": "Результат превышает максимальный болюс вашего профиля. Доза не уменьшается автоматически.",
        "below_target": "Глюкоза ниже целевого значения: итог уменьшен.",
    ]

    public static func message(_ code: String) -> String { messages[code] ?? code }
}
