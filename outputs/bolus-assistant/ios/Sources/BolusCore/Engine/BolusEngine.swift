import Foundation

/// Pure deterministic bolus engine — Swift port of `backend/app/bolus/engine.py`.
///
/// Never depends on AI, network, persistence or UI. All arithmetic reproduces
/// Python `Decimal(str(x))` in the default context, so results match the reference
/// implementation exactly. Any change of the math requires a new algorithm version.
public enum BolusEngine {
    public static let algorithmVersion = "bolus-v1.1.0"
    /// Legacy snapshots without a device step preserve the original 0.1 U policy.
    public static let legacyIncrement = 0.1

    public struct Input: Codable, Equatable, Sendable {
        /// Glucose in mmol/L; `nil` = missing.
        public var glucose: Double?
        /// Must be `mmol/L` (input in mg/dL is converted before the engine).
        public var unit: String
        public var carbs: Double
        public var icr: Double
        public var isf: Double
        public var target: Double
        public var correctAbove: Double
        public var dia: Double
        public var iob: Double
        public var maxBolus: Double
        /// `nil` = missing or unparsable measurement time.
        public var measuredAt: Date?
        /// `nil` = legacy 0.1 U step.
        public var bolusIncrement: Double?

        public init(glucose: Double?, unit: String = "mmol/L", carbs: Double, icr: Double, isf: Double, target: Double,
                    correctAbove: Double, dia: Double, iob: Double, maxBolus: Double, measuredAt: Date?, bolusIncrement: Double?) {
            self.glucose = glucose
            self.unit = unit
            self.carbs = carbs
            self.icr = icr
            self.isf = isf
            self.target = target
            self.correctAbove = correctAbove
            self.dia = dia
            self.iob = iob
            self.maxBolus = maxBolus
            self.measuredAt = measuredAt
            self.bolusIncrement = bolusIncrement
        }
    }

    public enum Status: String, Codable, Sendable {
        case ok
        case blocked
    }

    /// Calculation snapshot. JSON keys match the reference backend.
    public struct Result: Codable, Equatable, Sendable {
        public var algorithmVersion: String
        public var calculationStatus: Status
        public var recommendedBolus: Double?
        public var warnings: [String]
        public var mealBolus: Double
        public var rawCorrectionBolus: Double
        public var correctionBolus: Double
        public var iob: Double
        public var iobAdjustment: Double
        public var cycleAdjustment: Double
        public var personalizationAdjustment: Double
        public var unroundedBolus: Double?
        public var roundingIncrement: Double?
        public var roundingAdjustment: Double?

        enum CodingKeys: String, CodingKey {
            case algorithmVersion = "algorithm_version", calculationStatus = "calculation_status"
            case recommendedBolus = "recommended_bolus", warnings
            case mealBolus = "meal_bolus", rawCorrectionBolus = "raw_correction_bolus", correctionBolus = "correction_bolus"
            case iob, iobAdjustment = "iob_adjustment", cycleAdjustment = "cycle_adjustment"
            case personalizationAdjustment = "personalization_adjustment", unroundedBolus = "unrounded_bolus"
            case roundingIncrement = "rounding_increment", roundingAdjustment = "rounding_adjustment"
        }
    }

    public static func calculate(_ input: Input, at now: Date) -> Result {
        let errors = SafetyLayer.validateInputs(input, now: now)
        var result = Result(algorithmVersion: algorithmVersion, calculationStatus: .blocked, recommendedBolus: nil,
                            warnings: errors, mealBolus: 0, rawCorrectionBolus: 0, correctionBolus: 0, iob: input.iob,
                            iobAdjustment: 0, cycleAdjustment: 0, personalizationAdjustment: 0,
                            unroundedBolus: nil, roundingIncrement: nil, roundingAdjustment: nil)
        guard errors.isEmpty, let glucoseValue = input.glucose,
              let glucose = PyDecimal(glucoseValue), let carbs = PyDecimal(input.carbs), let icr = PyDecimal(input.icr),
              let isf = PyDecimal(input.isf), let target = PyDecimal(input.target), let correctAbove = PyDecimal(input.correctAbove),
              let iob = PyDecimal(input.iob), let increment = PyDecimal(input.bolusIncrement ?? legacyIncrement) else {
            return result
        }
        let meal = carbs / icr
        let raw = (glucose - target) / isf
        // Correct Above gates positive correction only. Below-target glucose reduces total.
        let correction = glucose > correctAbove || raw < .zero ? raw : .zero
        let beforeIOB = meal + correction
        let adjustment = PyDecimal.pyMin(iob, PyDecimal.pyMax(.zero, beforeIOB))
        let unrounded = PyDecimal.pyMax(.zero, beforeIOB - adjustment)
        let resultErrors = SafetyLayer.validateResult(unrounded.doubleValue, maxBolus: input.maxBolus)
        let rounded = (unrounded / increment).floorToIntegral() * increment
        result.mealBolus = meal.doubleValue
        result.rawCorrectionBolus = raw.doubleValue
        result.correctionBolus = correction.doubleValue
        result.iobAdjustment = adjustment.doubleValue
        result.unroundedBolus = unrounded.doubleValue
        result.roundingIncrement = increment.doubleValue
        result.roundingAdjustment = (unrounded - rounded).doubleValue
        if !resultErrors.isEmpty {
            result.warnings = resultErrors
            return result
        }
        result.calculationStatus = .ok
        result.recommendedBolus = rounded.doubleValue
        result.warnings = raw < .zero ? ["below_target"] : []
        return result
    }
}
