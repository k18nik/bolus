import Foundation

/// Insulin action model (port of `InsulinActionModel` protocol).
public protocol InsulinActionModel: Sendable {
    var version: String { get }
    func remaining(elapsedHours: Double, diaHours: Double) throws -> Double
}

public enum IOBError: Error, Equatable, LocalizedError {
    case invalidActionDuration
    case invalidActualDose

    public var errorDescription: String? {
        switch self {
        case .invalidActionDuration: return "В записи инсулина некорректная DIA (допустимо 2–8 ч)."
        case .invalidActualDose: return "В дневнике есть некорректная доза инсулина."
        }
    }
}

/// `linear-remaining-v1.0.0`: `remaining = max(0, 1 - elapsedHours / DIA)`.
/// A deterministic research model, not a validated pharmacokinetic curve.
public struct LinearActionModel: InsulinActionModel {
    public static let modelVersion = "linear-remaining-v1.0.0"
    public let version = LinearActionModel.modelVersion

    public init() {}

    public func remaining(elapsedHours: Double, diaHours: Double) throws -> Double {
        guard elapsedHours.isFinite, diaHours.isFinite, diaHours >= 2, diaHours <= 8 else {
            throw IOBError.invalidActionDuration
        }
        if elapsedHours < 0 { return 0 }
        return pyMax(0, pyMin(1, 1 - elapsedHours / diaHours))
    }
}

/// A confirmed, actually administered dose.
public struct AdministeredDose: Equatable, Sendable {
    public var units: Double
    public var administeredAt: Date
    /// DIA saved with the injection at the time it was given.
    public var diaHours: Double
    public var insulinType: InsulinType

    public init(units: Double, administeredAt: Date, diaHours: Double, insulinType: InsulinType = .rapid) {
        self.units = units
        self.administeredAt = administeredAt
        self.diaHours = diaHours
        self.insulinType = insulinType
    }
}

/// Port of `backend/app/iob/engine.py`.
public enum IOBEngine {
    public static let modelVersion = LinearActionModel.modelVersion
    /// The reference repository only loads doses from the last 8 hours (max DIA).
    public static let lookbackSeconds: TimeInterval = 8 * 3600
    /// DIA used by the reference implementation for legacy rapid entries without `dia`.
    public static let legacyDefaultDIA = 4.0

    /// Sums only actually administered rapid insulin; basal doses are excluded.
    /// Recommendations are never doses: callers pass diary insulin entries only.
    public static func calculate(_ doses: [AdministeredDose], at now: Date,
                                 model: InsulinActionModel = LinearActionModel()) throws -> Double {
        var total = 0.0
        for dose in doses {
            if dose.insulinType == .basal { continue }
            guard dose.units.isFinite, dose.units >= 0 else { throw IOBError.invalidActualDose }
            let elapsedHours = Micros.seconds(from: dose.administeredAt, to: now) / 3600
            total += dose.units * (try model.remaining(elapsedHours: elapsedHours, diaHours: dose.diaHours))
        }
        return total
    }
}

/// Python builtin `max(a, b)` (keeps `a` on ties).
@inline(__always) func pyMax(_ a: Double, _ b: Double) -> Double { b > a ? b : a }
/// Python builtin `min(a, b)` (keeps `a` on ties).
@inline(__always) func pyMin(_ a: Double, _ b: Double) -> Double { b < a ? b : a }
