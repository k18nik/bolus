import Foundation

/// Platform-independent PDF content (port of `backend/app/reports/pdf_renderer.py`).
/// The app draws these blocks on A4 pages with UIKit; no network and no AI involved.
public struct ReportChart: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case line, bar }
    public var title: String
    public var kind: Kind
    public var points: [ReportPoint]
    public var xLabels: [ReportAxisLabel]
    public var yLabel: String
    public var minimumTop: Double
    public var rangeBand: ClosedRange<Double>?
    /// Hex color, e.g. `#359679`.
    public var color: String
    public var note: String?
}

public struct ReportPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

public struct ReportAxisLabel: Equatable, Sendable {
    public var x: Double
    public var text: String
    public init(_ x: Double, _ text: String) { self.x = x; self.text = text }
}

public enum ReportBlock: Equatable, Sendable {
    case title(String)
    case section(String)
    case note(String)
    /// Column widths are relative weights.
    case table(headers: [String], rows: [[String]], widths: [Double])
    case chart(ReportChart)
    case pageBreak
}

public struct ReportDocument: Equatable, Sendable {
    public var title: String
    public var blocks: [ReportBlock]
    public var footer: String
}

public struct ReportInput: Sendable {
    public var options: ReportOptions
    /// All diary entries; the builder keeps only the selected period.
    public var entries: [DiaryRecord]
    public var profiles: [TherapyProfileRecord]
    public var calculations: [BolusCalculationRecord]
    public var cycles: [CycleRecord]
    public var foods: [FoodRecord]
    public var preferences: AppPreferences
    public var timeZone: TimeZone
    public var generatedAt: Date

    public init(options: ReportOptions, entries: [DiaryRecord], profiles: [TherapyProfileRecord], calculations: [BolusCalculationRecord],
                cycles: [CycleRecord], foods: [FoodRecord], preferences: AppPreferences, timeZone: TimeZone, generatedAt: Date) {
        self.options = options
        self.entries = entries
        self.profiles = profiles
        self.calculations = calculations
        self.cycles = cycles
        self.foods = foods
        self.preferences = preferences
        self.timeZone = timeZone
        self.generatedAt = generatedAt
    }
}

public enum ReportBuilder {
    static func f(_ value: Double?, _ digits: Int = 2) -> String { BolusFormat.decimal(value, digits) }

    /// Calculations made within the period (local dates).
    public static func calculations(_ input: ReportInput) -> [BolusCalculationRecord] {
        input.calculations.filter {
            let day = LocalDate(date: $0.calculatedAt, timeZone: input.timeZone)
            return day >= input.options.from && day <= input.options.to
        }
    }

    /// Cycles overlapping the period.
    public static func cycles(_ input: ReportInput) -> [CycleRecord] {
        input.cycles.filter { $0.startDate <= input.options.to && $0.startDate.adding(days: $0.cycleLength - 1) >= input.options.from }
    }

    /// Tables for CSV/XLSX (period data, like the server export).
    public static func tables(_ input: ReportInput) -> [ReportTable] {
        let o = input.options
        let report = AnalyticsEngine.report(input.entries, from: o.from, to: o.to, timeZone: input.timeZone, now: input.generatedAt)
        let tables = ReportTables.build(entries: report.entries, profiles: input.profiles, calculations: calculations(input),
                                        cycles: cycles(input), foods: input.foods, timeZone: input.timeZone, unit: input.preferences.glucoseUnit,
                                        includeNutrition: o.includeNutrition, includeCycle: o.includeCycle)
        return [ReportTables.summary(report.metrics, from: o.from, to: o.to, timeZone: input.timeZone, unit: input.preferences.glucoseUnit)] + tables
    }

    public static func pdfContent(_ input: ReportInput) -> ReportDocument {
        let o = input.options
        let unit = input.preferences.glucoseUnit
        let factor = unit.factor
        let unitLabel = unit.label
        let zone = input.timeZone
        let report = AnalyticsEngine.report(input.entries, from: o.from, to: o.to, timeZone: zone, now: input.generatedAt)
        let m = report.metrics
        var blocks: [ReportBlock] = [.title("BOLUS / DIABETES REPORT"), .section(o.type.title),
                                     .note("Период: \(o.from) – \(o.to) | Единицы глюкозы: \(unitLabel) | Часовой пояс: \(zone.identifier)")]
        var metricRows: [[String]] = [
            ["Средняя глюкоза, \(unitLabel)", f(m.meanGlucose.map { $0 * factor })],
            ["TIR / в диапазоне, % измерений", f(m.tir)], ["TBR / ниже диапазона, % измерений", f(m.tbr)],
            ["TAR / выше диапазона, % измерений", f(m.tar)], ["CV / коэффициент вариации, %", f(m.coefficientOfVariation)],
            // Insulin per day excludes basal insulin, which is listed on its own.
            ["Инсулин в сутки (без базального), ЕД", m.bolusInsulin.map { f($0) } ?? "нет записей"],
            ["Базальный инсулин в сутки (отдельно), ЕД", m.basalInsulin.map { f($0) } ?? "нет записей"],
        ]
        if o.includeNutrition { metricRows.append(["Углеводы в сутки, г", m.carbsPerDay.map { f($0) } ?? "нет записей"]) }
        metricRows.append(["Записанных измерений", String(m.sampleSize)])
        blocks.append(.table(headers: ["Показатель", "Значение"], rows: metricRows, widths: [365, 146]))
        blocks.append(.note("Диапазон: \(f(AnalyticsEngine.rangeLow * factor, 1))–\(f(AnalyticsEngine.rangeHigh * factor, 1)) \(unitLabel). При ручном вводе доля измерений не равна доле времени CGM. Дни без записей входят в знаменатель суточных сумм; отсутствие записи не означает отсутствие инсулина или еды."))
        blocks.append(.note("Метрики рассчитаны на устройстве (детерминированно, без сети). AI-резюме не включено. Отчёт описывает наблюдения, не устанавливает диагноз."))

        let daily = report.daily
        let step = max(1, daily.count / 6)
        let labels = daily.enumerated().filter { $0.offset % step == 0 }.map { ReportAxisLabel(Double($0.offset), dayMonth($0.element.date)) }
        let glucoseBand = (AnalyticsEngine.rangeLow * factor)...(AnalyticsEngine.rangeHigh * factor)
        if o.includeGraphs {
            blocks.append(.pageBreak)
            if [.doctor, .summary, .glucose, .raw].contains(o.type) {
                blocks.append(.chart(ReportChart(title: "Суточный профиль глюкозы", kind: .line,
                                                 points: report.hourly.map { ReportPoint(Double($0.hour), $0.mean * factor) },
                                                 xLabels: [0, 6, 12, 18, 23].map { ReportAxisLabel(Double($0), String(format: "%02d:00", $0)) },
                                                 yLabel: unitLabel, minimumTop: 15 * factor, rangeBand: glucoseBand, color: "#359679",
                                                 note: "Средние значения по часам на основе фактических измерений. Не является CGM/AGP-профилем.")))
                let start = o.from.startOfDay(in: zone)
                let glucosePoints = report.entries.filter { $0.kind == .glucose }.compactMap { entry -> ReportPoint? in
                    guard let value = entry.data.double("value_mmol") else { return nil }
                    return ReportPoint(entry.occurredAt.timeIntervalSince(start) / 86400, value * factor)
                }
                blocks.append(.chart(ReportChart(title: "Глюкоза за выбранный период", kind: .line, points: glucosePoints, xLabels: labels,
                                                 yLabel: unitLabel, minimumTop: 15 * factor, rangeBand: glucoseBand, color: "#359679", note: nil)))
                blocks.append(.pageBreak)
                blocks.append(.chart(ReportChart(title: "Распределение измерений", kind: .bar,
                                                 points: [m.tbr, m.tir, m.tar].enumerated().map { ReportPoint(Double($0.offset), $0.element ?? 0) },
                                                 xLabels: [ReportAxisLabel(0, "Ниже"), ReportAxisLabel(1, "В диапазоне"), ReportAxisLabel(2, "Выше")],
                                                 yLabel: "%", minimumTop: 100, rangeBand: nil, color: "#359679", note: nil)))
                blocks.append(.chart(ReportChart(title: "Средняя глюкоза по дням", kind: .line,
                                                 points: daily.enumerated().compactMap { index, row in row.summary.meanGlucose.map { ReportPoint(Double(index), $0 * factor) } },
                                                 xLabels: labels, yLabel: unitLabel, minimumTop: 15 * factor, rangeBand: glucoseBand, color: "#359679", note: nil)))
                blocks.append(.pageBreak)
            }
            if [.doctor, .summary, .insulin, .raw].contains(o.type) {
                blocks.append(.chart(ReportChart(title: "Фактически введённый инсулин по дням (без базального)", kind: .bar,
                                                 points: daily.enumerated().compactMap { index, row in row.summary.bolusInsulin.map { ReportPoint(Double(index), $0) } },
                                                 xLabels: labels, yLabel: "ЕД / сутки", minimumTop: 1, rangeBand: nil, color: "#9c90bd",
                                                 note: "Дни без записей инсулина не показаны как ноль.")))
                let purposes: [InsulinPurpose] = [.meal, .correction, .mealAndCorrection, .basal, .manual, .other]
                blocks.append(.chart(ReportChart(title: "Распределение инсулина по назначению", kind: .bar,
                                                 points: purposes.enumerated().map { ReportPoint(Double($0.offset), report.insulinByPurpose[$0.element] ?? 0) },
                                                 xLabels: ["Еда", "Коррекция", "Еда + корр.", "Базальный", "Вручную", "Другое"].enumerated().map { ReportAxisLabel(Double($0.offset), $0.element) },
                                                 yLabel: "ЕД за период", minimumTop: 1, rangeBand: nil, color: "#9c90bd", note: nil)))
                blocks.append(.pageBreak)
            }
            if o.includeNutrition && [.doctor, .summary, .nutrition, .raw].contains(o.type) {
                blocks.append(.chart(ReportChart(title: "Углеводы по дням", kind: .bar,
                                                 points: daily.enumerated().compactMap { index, row in row.summary.carbsPerDay.map { ReportPoint(Double(index), $0) } },
                                                 xLabels: labels, yLabel: "г / сутки", minimumTop: 1, rangeBand: nil, color: "#d4ad73", note: nil)))
                let types: [MealType] = [.breakfast, .lunch, .dinner, .snack]
                blocks.append(.chart(ReportChart(title: "Углеводы по приёмам пищи", kind: .bar,
                                                 points: types.enumerated().map { ReportPoint(Double($0.offset), report.carbsByMealType[$0.element] ?? 0) },
                                                 xLabels: types.enumerated().map { ReportAxisLabel(Double($0.offset), $0.element.label) },
                                                 yLabel: "г за период", minimumTop: 1, rangeBand: nil, color: "#d4ad73", note: nil)))
                blocks.append(.pageBreak)
            }
        }
        if o.includeNutrition && [.doctor, .summary, .nutrition, .raw].contains(o.type) {
            blocks.append(.section("Питание за период"))
            blocks.append(.table(headers: ["Показатель", "В сутки"], rows: [
                ["Энергия, ккал", m.caloriesPerDay.map { f($0) } ?? "нет записей"],
                ["Белки, г", report.proteinPerDay.map { f($0) } ?? "нет записей"],
                ["Жиры, г", report.fatPerDay.map { f($0) } ?? "нет записей"],
                ["Приёмов пищи", report.mealsPerDay.map { f($0) } ?? "нет записей"],
            ], widths: [365, 146]))
            blocks.append(.section("Продукты и блюда"))
            blocks.append(.table(headers: ["Продукт", "Раз", "Средние углеводы, г"],
                                 rows: report.topFoods.map { [$0.name, String($0.count), f($0.meanCarbs)] }, widths: [305, 66, 140]))
            blocks.append(.pageBreak)
        }
        let periodCycles = cycles(input)
        if o.includeCycle && !periodCycles.isEmpty {
            blocks.append(.section("Цикл и глюкоза"))
            let ordered = input.cycles.sorted { $0.startDate < $1.startDate }
            var byPhase: [CyclePhase: [Double]] = [:]
            var phaseOrder: [CyclePhase] = []
            for entry in report.entries where entry.kind == .glucose {
                guard let value = entry.data.double("value_mmol") else { continue }
                let day = LocalDate(date: entry.occurredAt, timeZone: zone)
                guard let cycle = ordered.last(where: { $0.startDate <= day }) else { continue }
                let phase = cycle.status(today: day).phase
                if byPhase[phase] == nil { phaseOrder.append(phase) }
                byPhase[phase, default: []].append(value)
            }
            blocks.append(.table(headers: ["Фаза (расчётная)", "Измерений", "Средняя, \(unitLabel)", "В диапазоне, %"],
                                 rows: phaseOrder.map { phase in
                                     let values = byPhase[phase] ?? []
                                     let inRange = Double(values.filter { $0 >= AnalyticsEngine.rangeLow && $0 <= AnalyticsEngine.rangeHigh }.count) / Double(values.count) * 100
                                     return [phase.label, String(values.count), f((PyStatistics.mean(values) ?? 0) * factor), f(inRange)]
                                 }, widths: [224, 80, 105, 102]))
            blocks.append(.note("Фазы приблизительны. Сравнение не учитывает различия в питании, активности и терапии; персональные коэффициенты не рассчитываются. Фаза цикла не меняет дозу."))
            blocks.append(.table(headers: ["Начало", "Длина, дней", "Фактическая овуляция"],
                                 rows: ordered.filter { $0.startDate <= o.to }.map { [$0.startDate.description, String($0.cycleLength), $0.actualOvulationDate?.description ?? BolusFormat.dash] },
                                 widths: [180, 150, 181]))
            blocks.append(.pageBreak)
        }
        blocks.append(.section("Терапевтический профиль"))
        let periodStart = o.from.startOfDay(in: zone)
        let periodEnd = o.to.adding(days: 1).startOfDay(in: zone)
        let relevant = input.profiles.sorted { $0.version < $1.version }.filter { $0.validFrom < periodEnd && ($0.validTo ?? .distantFuture) >= periodStart }
        if relevant.isEmpty { blocks.append(.note("В выбранном периоде нет сохранённого терапевтического профиля.")) }
        for profile in relevant {
            let s = profile.settings
            blocks.append(.section("Версия \(profile.version) — с \(LocalDate(date: profile.validFrom, timeZone: zone))"))
            blocks.append(.table(headers: ["Время", "ICR, г/ЕД", "ISF, ммоль/л/ЕД", "Цель", "Коррекция выше"],
                                 rows: s.segments.map { ["\($0.startTime)–\($0.endTime)", f($0.icr), f($0.isf), f($0.target), f($0.correctAbove)] },
                                 widths: [115, 86, 110, 90, 110]))
            blocks.append(.note("DIA: \(f(s.insulinActionDuration)) ч | max bolus: \(f(s.maxBolus)) ЕД | шаг болюса: \(BolusFormat.number(s.bolusIncrement)) ЕД | шаг базального: \(BolusFormat.number(s.basalIncrement)) ЕД"))
            blocks.append(.note("Быстрый инсулин: \(s.rapidInsulinName.isEmpty ? BolusFormat.dash : s.rapidInsulinName) | Базальный: \(s.basalInsulinName.isEmpty ? BolusFormat.dash : s.basalInsulinName)"))
        }
        let calcs = calculations(input)
        if !calcs.isEmpty {
            blocks.append(.section("Расчёты болюса"))
            blocks.append(.table(headers: ["Время", "Статус", "Расчёт, ЕД", "Факт, ЕД", "Алгоритм"],
                                 rows: calcs.sorted { $0.calculatedAt < $1.calculatedAt }.suffix(60).map { c in
                                     let result = c.result
                                     return [ISODate.format(c.calculatedAt, timeZone: zone).prefix(16).replacingOccurrences(of: "T", with: " "),
                                             result?.calculationStatus == .ok ? "ok" : "заблокирован", f(result?.recommendedBolus), f(c.actualBolus), c.algorithmVersion]
                                 }, widths: [130, 90, 80, 80, 131]))
        }
        blocks.append(.section("Выявленные паттерны"))
        blocks.append(.note("Автоматический анализ сопоставимых эпизодов и персональные предложения отключены. Отдельные высокие или низкие измерения не меняют профиль."))
        blocks.append(.section("Активность и Apple «Здоровье»"))
        blocks.append(.table(headers: ["Тренировок / записей", "Длительность, мин", "Из Apple Health"],
                             rows: [[String(report.workouts), report.activityMinutes.map { f($0) } ?? "нет записей", String(report.appleHealthWorkouts)]],
                             widths: [180, 180, 151]))
        if report.daysWithSteps > 0 {
            blocks.append(.note("Дней со сводкой шагов: \(report.daysWithSteps); в среднем \(f(report.meanStepsOnRecordedDays, 0)) шагов в такие дни."))
        }
        blocks.append(.note("Дневные сводки Apple Health не суммируются с тренировками. Активность не меняет рассчитанную дозу инсулина."))
        let footer = "Bolus | \(ISODate.format(input.generatedAt, timeZone: zone).prefix(16).replacingOccurrences(of: "T", with: " ")) | \(unitLabel)"
        return ReportDocument(title: "Bolus — Diabetes Report", blocks: blocks, footer: footer)
    }

    static func dayMonth(_ date: LocalDate) -> String { String(format: "%02d.%02d", date.day, date.month) }
}
