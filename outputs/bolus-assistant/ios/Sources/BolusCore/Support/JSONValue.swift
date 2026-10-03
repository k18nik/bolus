import Foundation

/// Untyped JSON used for snapshots and entry payloads (`data` in the reference
/// backend). Unknown keys survive round trips, which keeps imported records intact.
public enum JSONValue: Codable, Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        // Strings first: with the NaN/Infinity decoding strategy a text such as "NaN" would
        // otherwise turn into a number. Typed `Double` fields still decode those strings.
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
        if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var objectValue: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    public var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var doubleValue: Double? { if case .number(let v) = self { return v }; return nil }
    public var isNull: Bool { self == .null }

    /// Double for numbers, nil for null/missing — never a substituted zero.
    public func double(_ key: String) -> Double? { self[key]?.doubleValue }
    public func string(_ key: String) -> String? { self[key]?.stringValue }

    /// Shallow merge: keys of `other` override (Python `{**a, **b}`).
    public func merging(_ other: JSONValue) -> JSONValue {
        guard case .object(var base) = self, case .object(let extra) = other else { return other }
        for (key, value) in extra { base[key] = value }
        return .object(base)
    }

    public static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try BolusJSON.decoder.decode(JSONValue.self, from: BolusJSON.encoder.encode(value))
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try BolusJSON.decoder.decode(type, from: BolusJSON.encoder.encode(self))
    }
}

/// Shared JSON configuration: sorted keys for deterministic files, NaN/Infinity as
/// strings (Python writes them as bare literals; standard JSON cannot).
public enum BolusJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return encoder
    }

    public static var prettyEncoder: JSONEncoder {
        let encoder = encoder
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return decoder
    }

    public static func data(_ value: JSONValue) -> Data {
        (try? encoder.encode(value)) ?? Data("null".utf8)
    }

    public static func value(_ data: Data) -> JSONValue {
        (try? decoder.decode(JSONValue.self, from: data)) ?? .null
    }
}

/// ISO-string coding for `Date` inside snapshots.
public struct ISODateString: Codable, Hashable, Sendable {
    public var date: Date
    public init(_ date: Date) { self.date = date }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let date = ISODate.parse(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO date \(text)")
        }
        self.date = date
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ISODate.format(date))
    }
}
