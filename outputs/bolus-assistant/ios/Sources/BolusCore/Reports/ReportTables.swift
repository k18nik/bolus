import Foundation

public enum ReportType: String, CaseIterable, Codable, Sendable {
    case doctor, summary, glucose, insulin, nutrition, cycle, raw

    public var title: String {
        switch self {
        case .doctor: return "Отчёт для врача"
        case .summary: return "Общая сводка"
        case .glucose: return "Глюкоза"
        case .insulin: return "Инсулин"
        case .nutrition: return "Питание"
        case .cycle: return "Менструальный цикл"
        case .raw: return "Исходные данные"
        }
    }
}

public enum ReportFormat: String, CaseIterable, Codable, Sendable {
    case pdf, csv, xlsx, json

    public var title: String {
        switch self {
        case .pdf: return "PDF · для чтения и печати"
        case .csv: return "CSV · архив таблиц"
        case .xlsx: return "Excel · все таблицы"
        case .json: return "JSON · полная резервная копия"
        }
    }

    /// CSV reports are a ZIP with one CSV per table.
    public var fileExtension: String { self == .csv ? "zip" : rawValue }
}

public struct ReportOptions: Equatable, Sendable {
    public var type: ReportType
    public var format: ReportFormat
    public var from: LocalDate
    public var to: LocalDate
    public var includeGraphs: Bool
    public var includeNutrition: Bool
    public var includeCycle: Bool

    public init(type: ReportType = .doctor, format: ReportFormat = .pdf, from: LocalDate, to: LocalDate,
                includeGraphs: Bool = true, includeNutrition: Bool = true, includeCycle: Bool = true) {
        self.type = type
        self.format = format
        self.from = from
        self.to = to
        self.includeGraphs = includeGraphs
        self.includeNutrition = includeNutrition
        self.includeCycle = includeCycle
    }

    /// Period presets: 7/14/30/90 days ending today, or a custom range up to 367 days.
    public static func period(days: Int, endingAt today: LocalDate) -> (LocalDate, LocalDate) {
        (today.adding(days: -(max(days, 1) - 1)), today)
    }

    public func validate() throws {
        guard from <= to, to.days(since: from) <= 366 else { throw BolusError.validation("Выберите период до 366 дней") }
    }

    public var fileName: String { "bolus-\(type.rawValue)-\(from)-\(to).\(format.fileExtension)" }
}

public enum ReportCell: Equatable, Sendable {
    case empty
    case text(String)
    case number(Double)
    case bool(Bool)
}

public struct ReportTable: Equatable, Sendable {
    public var name: String
    public var columns: [String]
    public var rows: [[ReportCell]]

    public init(name: String, columns: [String], rows: [[ReportCell]]) {
        self.name = name
        self.columns = columns.isEmpty ? ["No data"] : columns
        self.rows = rows
    }

    /// Builds a table from dictionaries: preferred columns first, then the rest sorted.
    public init(name: String, preferred: [String], records: [[String: JSONValue]]) {
        var keys = Set<String>()
        records.forEach { keys.formUnion($0.keys) }
        let columns = preferred.filter(keys.contains) + keys.subtracting(preferred).sorted()
        self.init(name: name, columns: columns, rows: records.map { record in columns.map { ReportTables.cell(record[$0]) } })
    }
}

/// Port of `backend/app/reports/generator.py` (`tables_for`, `safe_cell`, `csv_bytes`).
public enum ReportTables {
    static let preferredColumns: [EntryKind: [String]] = [
        .glucose: ["value", "unit", "value_mmol", "source", "trend", "note"],
        .insulin: ["units", "insulin_type", "insulin_name", "purpose", "insulin_id", "active_ingredient", "dose_increment", "dia",
                   "action_model", "related_bolus_calculation_id", "related_meal_id", "note"],
        .meal: ["name", "meal_type", "total_carbs", "total_protein", "total_fat", "total_calories", "note"],
        .activity: ["name", "duration_minutes", "intensity", "source", "source_name", "source_kind", "external_id", "ended_at",
                    "active_energy", "distance_km", "note"],
        .activitySummary: ["name", "local_date", "steps", "active_energy", "energy_unit", "exercise_minutes", "distance_km", "source",
                           "source_kind", "timezone", "note"],
    ]
    public static let sheets: [(String, EntryKind)] = [
        ("Glucose", .glucose), ("Insulin", .insulin), ("Meals", .meal), ("Activities", .activity), ("Activity Summaries", .activitySummary),
    ]

    static func cell(_ value: JSONValue?) -> ReportCell {
        switch value {
        case nil, .null?: return .empty
        case .bool(let flag)?: return .bool(flag)
        case .number(let number)?: return .number(number)
        case .string(let text)?: return .text(text)
        case let nested?: return .text(String(decoding: (try? jsonEncoder.encode(nested)) ?? Data(), as: UTF8.self))
        }
    }

    static var jsonEncoder: JSONEncoder {
        let encoder = BolusJSON.encoder
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func build(entries: [DiaryRecord], profiles: [TherapyProfileRecord], calculations: [BolusCalculationRecord],
                             cycles: [CycleRecord], foods: [FoodRecord], timeZone: TimeZone, unit: GlucoseUnit,
                             includeNutrition: Bool = true, includeCycle: Bool = true) -> [ReportTable] {
        var tables: [ReportTable] = []
        for (name, kind) in sheets {
            if !includeNutrition && kind == .meal { continue }
            let records: [[String: JSONValue]] = entries.filter { $0.kind == kind }.map { entry in
                var data = entry.data.objectValue ?? [:]
                data.removeValue(forKey: "items")
                if kind == .glucose, let mmol = data["value_mmol"]?.doubleValue {
                    data["value"] = .number(PyFloat.round(mmol * unit.factor, 2))
                    data["unit"] = .string(unit.rawValue)
                }
                data["id"] = .string(entry.id.uuidString.lowercased())
                data["timestamp"] = .string(ISODate.format(entry.occurredAt, timeZone: timeZone))
                return data
            }
            tables.append(ReportTable(name: name, preferred: ["id", "timestamp"] + (preferredColumns[kind] ?? []), records: records))
        }
        if includeNutrition {
            let items: [[String: JSONValue]] = entries.filter { $0.kind == .meal }.flatMap { entry -> [[String: JSONValue]] in
                (entry.data["items"]?.arrayValue ?? []).map { item in
                    var row = item.objectValue ?? [:]
                    row["meal_id"] = .string(entry.id.uuidString.lowercased())
                    return row
                }
            }
            tables.append(ReportTable(name: "Meal Items", preferred: ["meal_id", "name_snapshot", "food_source", "food_id", "amount", "unit",
                                                                   "grams", "carbs", "protein", "fat", "calories", "fiber", "sugar"], records: items))
        }
        if includeCycle {
            tables.append(ReportTable(name: "Cycle", columns: ["id", "start_date", "end_date", "cycle_length", "actual_ovulation_date"],
                                      rows: cycles.sorted { $0.startDate < $1.startDate }.map { c in
                                          [.text(c.id.uuidString.lowercased()), .text(c.startDate.description), c.endDate.map { .text($0.description) } ?? .empty,
                                           .number(Double(c.cycleLength)), c.actualOvulationDate.map { .text($0.description) } ?? .empty]
                                      }))
        }
        tables.append(ReportTable(name: "Bolus Calculations",
                                  columns: ["id", "calculated_at", "algorithm_version", "calculation_status", "recommended_bolus", "actual_bolus",
                                            "input_snapshot", "calculation_snapshot"],
                                  rows: calculations.sorted { $0.calculatedAt < $1.calculatedAt }.map { c in
                                      [.text(c.id.uuidString.lowercased()), .text(ISODate.format(c.calculatedAt, timeZone: timeZone)),
                                       .text(c.algorithmVersion), cell(c.calculationSnapshot["calculation_status"]),
                                       cell(c.calculationSnapshot["recommended_bolus"]), c.actualBolus.map(ReportCell.number) ?? .empty,
                                       cell(c.inputSnapshot), cell(c.calculationSnapshot)]
                                  }))
        tables.append(ReportTable(name: "Therapy Profiles", columns: ["id", "version", "valid_from", "valid_to", "status", "source", "data"],
                                  rows: profiles.sorted { $0.version < $1.version }.map { p in
                                      [.text(p.id.uuidString.lowercased()), .number(Double(p.version)), .text(ISODate.format(p.validFrom, timeZone: timeZone)),
                                       p.validTo.map { .text(ISODate.format($0, timeZone: timeZone)) } ?? .empty, .text(p.status), .text(p.source),
                                       cell(try? JSONValue.encode(p.settings))]
                                  }))
        if includeNutrition {
            tables.append(ReportTable(name: "Foods", columns: ["id", "name", "is_recipe", "is_favorite", "source", "data"],
                                      rows: foods.sorted { $0.name < $1.name }.map { f in
                                          [.text(f.id.uuidString.lowercased()), .text(f.name), .bool(f.isRecipe), .bool(f.isFavorite), .text(f.source),
                                           cell(try? JSONValue.encode(f))]
                                      }))
        }
        tables.append(ReportTable(name: "Notes", columns: ["id", "timestamp", "note"],
                                  rows: entries.filter { $0.kind == .note }.map { e in
                                      [.text(e.id.uuidString.lowercased()), .text(ISODate.format(e.occurredAt, timeZone: timeZone)), .text(e.noteText)]
                                  }))
        tables.append(ReportTable(name: "Patterns", columns: [], rows: []))
        return tables
    }

    /// Summary row (metrics converted to the display unit like the Excel export).
    public static func summary(_ metrics: AnalyticsEngine.Summary, from: LocalDate, to: LocalDate, timeZone: TimeZone, unit: GlucoseUnit) -> ReportTable {
        var record = (try? JSONValue.encode(metrics).objectValue) ?? [:]
        for key in ["mean_glucose", "median_glucose", "min", "max", "standard_deviation"] where unit == .mgdl {
            if let value = record[key]?.doubleValue { record[key] = .number(PyFloat.round(value * 18, 2)) }
        }
        record["period"] = .string("\(from) — \(to)")
        record["timezone"] = .string(timeZone.identifier)
        record["glucose_unit"] = .string(unit.rawValue)
        let order = ["period", "timezone", "glucose_unit", "sample_size", "coverage_method", "mean_glucose", "median_glucose", "min", "max",
                     "standard_deviation", "coefficient_of_variation", "tir", "tbr", "tar", "daily_insulin", "basal_insulin", "bolus_insulin",
                     "carbs_per_day", "calories_per_day", "corrections_per_day", "days"]
        return ReportTable(name: "Summary", preferred: order, records: [record])
    }

    /// Spreadsheet formula injection protection.
    public static func safeCell(_ text: String) -> String {
        guard let first = text.unicodeScalars.first else { return text }
        return ["=", "+", "-", "@", "\t", "\r"].contains(String(first)) ? "'" + text : text
    }

    /// Python-like number text (`5` for integral values, shortest repr otherwise).
    public static func numberText(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return value.description
    }

    public static func text(_ cell: ReportCell) -> String {
        switch cell {
        case .empty: return ""
        case .bool(let flag): return flag ? "True" : "False"
        case .number(let value): return numberText(value)
        case .text(let value): return safeCell(value)
        }
    }

    /// UTF-8 with BOM, CRLF, minimal quoting (Python `csv` excel dialect).
    public static func csv(_ table: ReportTable) -> Data {
        func field(_ value: String) -> String {
            value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
        }
        var lines = [table.columns.map(field).joined(separator: ",")]
        for row in table.rows { lines.append(row.map { field(text($0)) }.joined(separator: ",")) }
        return Data([0xEF, 0xBB, 0xBF]) + Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    public static func csvArchive(_ tables: [ReportTable], modified: Date) -> Data {
        var zip = ZipWriter()
        for table in tables {
            zip.add(path: table.name.lowercased().replacingOccurrences(of: " ", with: "_") + ".csv", data: csv(table), modified: modified)
        }
        return zip.finalize()
    }
}
