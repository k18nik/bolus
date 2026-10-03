import Foundation

/// Port of `backend/app/services/insulins.py`.
/// Name recognition classifies insulin; individual DIA is always profile-configured.
public enum InsulinCatalog {
    public struct Known: Equatable, Sendable {
        public let id: String
        public let name: String
        public let ingredient: String
        public let type: InsulinType
    }

    public static let known: [String: Known] = [
        "fiasp": Known(id: "fiasp", name: "Фиасп", ingredient: "инсулин аспарт", type: .rapid),
        "tresiba": Known(id: "tresiba", name: "Тресиба", ingredient: "инсулин деглудек", type: .basal),
    ]

    static let aliases: [(alias: String, id: String)] = [
        ("фиасп", "fiasp"), ("fiasp", "fiasp"), ("тресиба", "tresiba"), ("tresiba", "tresiba"),
    ]

    /// Allowed device steps, units.
    public static let doseSteps: [Double] = [0.1, 0.25, 0.5, 1.0, 2.0]
    public static let bolusSteps: [Double] = [1.0, 0.5, 0.25, 0.1]
    public static let basalSteps: [Double] = [1.0, 2.0, 0.5, 0.25, 0.1]

    public static func identify(_ name: String) -> Known? {
        let normalized = name.lowercased().replacingOccurrences(of: "®", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        for (alias, id) in aliases where normalized == alias || normalized.hasPrefix(alias + " ") {
            return known[id]
        }
        return nil
    }

    /// Throws when a known insulin is used with the wrong type.
    @discardableResult
    public static func checkType(_ name: String, _ type: InsulinType) throws -> Known? {
        let known = identify(name)
        if let known, known.type != type {
            throw BolusError.validation("\(known.name): выберите \(known.type == .basal ? "базальный" : "быстрый") инсулин")
        }
        return known
    }

    /// `Decimal(str(units)) % Decimal(str(step)) == 0`.
    public static func isDoseMultiple(_ units: Double, step: Double) -> Bool {
        guard let value = PyDecimal(units), let increment = PyDecimal(step), !increment.isZero else { return false }
        return PyDecimal.isIntegralMultiple(value, of: increment)
    }

    public struct Metadata: Codable, Equatable, Sendable {
        public var insulinID: String
        public var activeIngredient: String
        public var insulinType: InsulinType

        enum CodingKeys: String, CodingKey {
            case insulinID = "insulin_id", activeIngredient = "active_ingredient", insulinType = "insulin_type"
        }
    }

    public static func metadata(_ name: String, _ type: InsulinType) throws -> Metadata {
        let known = try checkType(name, type)
        return Metadata(insulinID: known?.id ?? "custom", activeIngredient: known?.ingredient ?? "", insulinType: type)
    }
}

public enum InsulinType: String, Codable, CaseIterable, Sendable {
    case rapid
    case basal
}

/// User-facing validation/business error with a Russian message.
public enum BolusError: Error, Equatable, LocalizedError, Sendable {
    case validation(String)
    case notFound(String)
    case conflict(String)

    public var errorDescription: String? {
        switch self {
        case .validation(let message), .notFound(let message), .conflict(let message): return message
        }
    }
}
