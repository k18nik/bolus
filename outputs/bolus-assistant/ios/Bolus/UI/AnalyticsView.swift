import SwiftUI
import Charts

struct HourlyChartPoint: Identifiable {
    let hour: Int
    let mean: Double
    var id: Int { hour }
}

struct DailyChartPoint: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

/// Local analytics (port of the Python analytics). Missing data is shown as «—» or
/// «нет записей», never as zero.
struct AnalyticsView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var days = 7
    @State private var report: AnalyticsEngine.Report?

    var body: some View {
        Screen {
            PageHeading(title: "Чуть больше понимания", subtitle: "Замечайте закономерности, опираясь на свои данные.")
            Picker("Период", selection: $days) {
                Text("24 ч").tag(1)
                Text("7 д").tag(7)
                Text("14 д").tag(14)
                Text("30 д").tag(30)
                Text("90 д").tag(90)
            }
            .pickerStyle(.segmented)
            if let report {
                content(report)
            } else {
                ProgressView("Собираем ваши наблюдения…").frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Аналитика")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { AIView() } label: { Image(systemName: "sparkles") }.accessibilityLabel("AI-ассистент")
            }
        }
        .task(id: "\(days)-\(store.revision)") { load() }
    }

    private func load() {
        let today = store.today
        let all = store.entries(from: today.adding(days: -(max(days, 2) - 1)).startOfDay(in: store.timeZone), to: Date().addingTimeInterval(EntryFactory.futureTolerance))
        if days == 1 {
            report = AnalyticsEngine.report(all, from: today.adding(days: -1), to: today, timeZone: store.timeZone, hours: 24)
        } else {
            report = AnalyticsEngine.report(all, from: today.adding(days: -(days - 1)), to: today, timeZone: store.timeZone)
        }
    }

    @ViewBuilder private func content(_ report: AnalyticsEngine.Report) -> some View {
        let m = report.metrics
        let unit = store.unit
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            stat("Средняя глюкоза", BolusFormat.glucose(m.meanGlucose, unit: unit), unit.label)
            stat("В диапазоне", BolusFormat.decimal(m.tir, 1), "% измерений")
            stat("Инсулин в сутки", m.bolusInsulin.map { BolusFormat.decimal($0) } ?? "нет записей", "ЕД · без базального")
            stat("Углеводы в сутки", m.carbsPerDay.map { BolusFormat.decimal($0, 1) } ?? "нет записей", "г")
        }
        Card {
            HStack {
                Text("История глюкозы").font(.headline).foregroundStyle(theme.text)
                Spacer()
                Text("\(m.sampleSize) измерений").font(.caption).foregroundStyle(theme.muted)
            }
            GlucoseChartView(entries: report.entries, unit: unit)
            Text("Проценты рассчитаны по записанным измерениям. При ручном вводе это не оценка времени CGM в диапазоне.")
                .font(.caption2).foregroundStyle(theme.muted)
        }
        Card {
            SectionTitle(title: "Распределение глюкозы")
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    Rectangle().fill(BolusTheme.below).frame(width: proxy.size.width * CGFloat((m.tbr ?? 0) / 100))
                    Rectangle().fill(BolusTheme.inRange).frame(width: proxy.size.width * CGFloat((m.tir ?? 0) / 100))
                    Rectangle().fill(BolusTheme.above).frame(width: proxy.size.width * CGFloat((m.tar ?? 0) / 100))
                }
            }
            .frame(height: 12)
            .background(theme.border)
            .clipShape(Capsule())
            DataRow(label: "Ниже диапазона (<3,9)", value: percent(m.tbr), dot: BolusTheme.below)
            DataRow(label: "В диапазоне (3,9–10)", value: percent(m.tir), dot: BolusTheme.inRange)
            DataRow(label: "Выше диапазона (>10)", value: percent(m.tar), dot: BolusTheme.above)
            DataRow(label: "Коэффициент вариации", value: percent(m.coefficientOfVariation))
            DataRow(label: "Медиана", value: BolusFormat.glucose(m.medianGlucose, unit: unit))
            DataRow(label: "Минимум / максимум", value: "\(BolusFormat.glucose(m.min, unit: unit)) / \(BolusFormat.glucose(m.max, unit: unit))")
            DataRow(label: "Стандартное отклонение", value: BolusFormat.glucose(m.standardDeviation, unit: unit))
        }
        if !report.hourly.isEmpty {
            Card {
                SectionTitle(title: "Суточный профиль", systemImage: "clock")
                Chart(report.hourly.map { HourlyChartPoint(hour: $0.hour, mean: unit.fromMmol($0.mean)) }) { point in
                    BarMark(x: .value("Час", point.hour), y: .value("Средняя", point.mean))
                        .foregroundStyle(BolusTheme.glucoseLine.opacity(0.8))
                }
                .chartXScale(domain: 0...23)
                .frame(height: 160)
                Text("Средние по часам на основе фактических измерений. Не является CGM/AGP-профилем.").font(.caption2).foregroundStyle(theme.muted)
            }
        }
        Card {
            SectionTitle(title: "Инсулин и питание")
            DataRow(label: "Инсулин в сутки (без базального)", value: m.bolusInsulin.map { BolusFormat.units($0) } ?? "нет записей")
            DataRow(label: "Базальный в сутки — отдельно", value: m.basalInsulin.map { BolusFormat.units($0) } ?? "нет записей")
            DataRow(label: "Коррекций в сутки", value: m.correctionsPerDay.map { BolusFormat.decimal($0) } ?? "нет записей")
            DataRow(label: "Энергия в сутки", value: m.caloriesPerDay.map { "\(BolusFormat.decimal($0, 0)) ккал" } ?? "нет записей")
            DataRow(label: "Белки / жиры в сутки", value: report.proteinPerDay.map { "\(BolusFormat.decimal($0, 1)) / \(BolusFormat.decimal(report.fatPerDay, 1)) г" } ?? "нет записей")
            DataRow(label: "Приёмов пищи в сутки", value: report.mealsPerDay.map { BolusFormat.decimal($0) } ?? "нет записей")
            if !report.topFoods.isEmpty {
                Text("Частые продукты").font(.footnote.weight(.semibold)).foregroundStyle(theme.text)
                ForEach(Array(report.topFoods.prefix(5).enumerated()), id: \.offset) { _, food in
                    DataRow(label: food.name, value: "\(food.count)× · \(BolusFormat.decimal(food.meanCarbs, 1)) г")
                }
            }
            Text("Дни без записей входят в знаменатель; отсутствие записи не означает отсутствие инсулина или еды.")
                .font(.caption2).foregroundStyle(theme.muted)
        }
        Card {
            SectionTitle(title: "Активность", systemImage: "figure.walk")
            DataRow(label: "Тренировок / записей", value: String(report.workouts))
            DataRow(label: "Длительность за период", value: report.activityMinutes.map { "\(BolusFormat.decimal($0, 0)) мин" } ?? "нет записей")
            DataRow(label: "Из Apple «Здоровье»", value: String(report.appleHealthWorkouts))
            DataRow(label: "Шаги в дни со сводкой", value: report.meanStepsOnRecordedDays.map { BolusFormat.decimal($0, 0) } ?? "нет данных")
            NavigationLink { HealthSyncView() } label: { Label("Импортировать из Apple «Здоровье»", systemImage: "heart") }
                .font(.footnote)
        }
        Card {
            SectionTitle(title: "Глюкоза рядом с тренировками", systemImage: "waveform.path.ecg")
            Text("Последнее измерение за час до начала и первое в течение двух часов после окончания. Наблюдаемая связь не означает причинность.")
                .font(.caption).foregroundStyle(theme.muted)
            if report.activityResponse.isEmpty {
                Text("Пока нет тренировок с измерениями до и после.").font(.footnote).foregroundStyle(theme.muted)
            } else {
                ForEach(Array(report.activityResponse.suffix(12).enumerated()), id: \.offset) { _, item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.name).font(.subheadline).foregroundStyle(theme.text)
                            Text(item.source == "apple_health" ? "Apple «Здоровье»" : "Дневник").font(.caption2).foregroundStyle(theme.muted)
                        }
                        Spacer()
                        Text("\(BolusFormat.glucose(item.before, unit: unit)) → \(BolusFormat.glucose(item.after, unit: unit))")
                            .font(.footnote).foregroundStyle(theme.text)
                        Text((item.change > 0 ? "+" : "") + BolusFormat.decimal(item.change * unit.factor, 1))
                            .font(.footnote.weight(.semibold)).foregroundStyle(theme.accent)
                    }
                }
            }
        }
        if days > 1 { dailyCard(report) }
    }

    private func dailyCard(_ report: AnalyticsEngine.Report) -> some View {
        Card {
            SectionTitle(title: "По дням", systemImage: "calendar")
            ForEach(Array(report.daily.reversed().enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.date.title("d MMMM, EEEE")).font(.footnote.weight(.semibold)).foregroundStyle(theme.text)
                    HStack {
                        Text("Средняя \(BolusFormat.glucose(row.summary.meanGlucose, unit: store.unit))")
                        Spacer()
                        Text("В диапазоне \(percent(row.summary.tir))")
                    }
                    HStack {
                        Text("Инсулин \(row.summary.bolusInsulin.map { BolusFormat.units($0) } ?? "—")")
                        Spacer()
                        Text("Углеводы \(row.summary.carbsPerDay.map { "\(BolusFormat.decimal($0, 1)) г" } ?? "—")")
                        Spacer()
                        Text("Активность \(row.activityMinutes.map { "\(BolusFormat.decimal($0, 0)) мин" } ?? "—")")
                    }
                }
                .font(.caption)
                .foregroundStyle(theme.muted)
                Divider()
            }
        }
    }

    private func stat(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(theme.muted)
            Text(value).font(.title2.weight(.bold)).foregroundStyle(theme.text).minimumScaleFactor(0.6).lineLimit(1)
            Text(unit).font(.caption2).foregroundStyle(theme.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardBackground())
    }

    private func percent(_ value: Double?) -> String {
        value.map { BolusFormat.decimal($0, 1) + "%" } ?? BolusFormat.dash
    }
}
