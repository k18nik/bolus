import XCTest
@testable import BolusCore

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
                                "Missing fixture \(name).json")
        return try Data(contentsOf: url)
    }

    static func json(_ name: String) throws -> JSONValue {
        try BolusJSON.decoder.decode(JSONValue.self, from: data(name))
    }
}

/// 2026-10-02T12:00:00Z — the fixed instant used by the Python tests.
let referenceInstant = ISODate.parse("2026-10-02T12:00:00+00:00")!

func date(_ iso: String) -> Date { ISODate.parse(iso)! }

/// Mirror of `data(**kw)` in `backend/tests/test_bolus.py`.
func bolusInput(glucose: Double? = 10.2, unit: String = "mmol/L", carbs: Double = 62, icr: Double = 10, isf: Double = 2,
                target: Double = 6, correctAbove: Double = 7, dia: Double = 4, iob: Double = 0.9, maxBolus: Double = 15,
                measuredAt: Date? = referenceInstant, bolusIncrement: Double? = nil) -> BolusEngine.Input {
    BolusEngine.Input(glucose: glucose, unit: unit, carbs: carbs, icr: icr, isf: isf, target: target, correctAbove: correctAbove,
                      dia: dia, iob: iob, maxBolus: maxBolus, measuredAt: measuredAt, bolusIncrement: bolusIncrement)
}

/// Decodes NaN/Infinity written as strings in shared vectors.
func vectorDouble(_ value: JSONValue?) -> Double? {
    switch value {
    case .number(let number): return number
    case .string("NaN"): return .nan
    case .string("Infinity"): return .infinity
    case .string("-Infinity"): return -.infinity
    default: return nil
    }
}

/// Deterministic pseudo-random generator for property tests (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
