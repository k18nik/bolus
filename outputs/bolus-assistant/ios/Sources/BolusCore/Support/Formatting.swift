import Foundation

/// Russian number formatting used by the UI and reports
/// (equivalent of `value.toLocaleString('ru-RU', {maximumFractionDigits})` on the web).
public enum BolusFormat {
    public static let dash = "—"

    private static func formatter(_ precision: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = precision
        formatter.decimalSeparator = ","
        formatter.groupingSeparator = "\u{00A0}"
        formatter.usesGroupingSeparator = true
        formatter.groupingSize = 3
        formatter.roundingMode = .halfUp
        return formatter
    }

    /// `—` for missing values: absence of data is never shown as zero.
    public static func decimal(_ value: Double?, _ precision: Int = 2) -> String {
        guard let value, value.isFinite else { return dash }
        return formatter(precision).string(from: NSNumber(value: value)) ?? dash
    }

    /// Up to three decimals without trailing zeros (doses, steps, ratios).
    public static func number(_ value: Double) -> String { decimal(value, 3) }

    public static func glucose(_ mmol: Double?, unit: GlucoseUnit) -> String {
        guard let mmol else { return dash }
        return decimal(unit.fromMmol(mmol), unit == .mgdl ? 0 : 1)
    }

    public static func units(_ value: Double?) -> String {
        guard let value else { return dash }
        return decimal(value, 2) + " ЕД"
    }

    /// Parses user input with either decimal separator; empty → nil.
    public static func parse(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }
}
