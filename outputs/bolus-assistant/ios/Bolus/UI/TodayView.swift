import SwiftUI

struct TodayView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.theme) private var theme
    let onAdd: (AddSection) -> Void
    var startupError: String?
    @State private var chartDays = 1
    @State private var selected: DiaryRecord?

    var body: some View {
        let _ = store.revision
        let todayEntries = store.entries(on: store.today)
        Screen {
            heading
            if let startupError { Notice(text: startupError, style: .error) }
            Notice(text: "Дневник работает без интернета. Данные хранятся только на этом iPhone.", systemImage: "lock.shield")
            GlucoseMetric(latest: store.latestGlucose(), todayEntries: todayEntries, onAdd: { onAdd(.glucose) })
            IOBMetric()
            // The calculator comes before food: the bolus is planned before eating.
            NavigationLink { BolusView() } label: {
                ShortcutCard(icon: "function", title: "Рассчитать болюс перед едой", subtitle: "С понятной расшифровкой, без интернета")
            }
            carbsMetric(todayEntries)
            chartCard
            eventsCard(todayEntries)
            mascotCard
            NavigationLink { CycleView() } label: { CycleShortcut() }
            NavigationLink { AnalyticsView() } label: {
                ShortcutCard(icon: "sparkles", title: "Чуть больше понимания", subtitle: "Замечайте закономерности вместе с дневником")
            }
            NavigationLink { HealthSyncView() } label: {
                ShortcutCard(icon: "heart.fill", title: "Apple «Здоровье»", subtitle: healthSubtitle)
            }
            Label("Только вы управляете своими данными", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(theme.muted).frame(maxWidth: .infinity)
        }
        .navigationTitle("Сегодня")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { onAdd(.glucose) } label: { Image(systemName: "plus.circle.fill") }
                    .accessibilityLabel("Добавить запись")
            }
        }
        .sheet(item: $selected) { entry in
            NavigationStack { EntryDetailView(entry: entry) }.environment(\.theme, theme)
        }
    }

    private var healthSubtitle: String {
        guard store.preferences.healthAutoSync else { return "Подключите автоматическую синхронизацию тренировок и активности" }
        guard let last = store.preferences.healthLastSync else { return "Автосинхронизация включена" }
        return "Автосинхронизация включена · \(last.dateTime(store.timeZone))"
    }

    private var heading: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let greeting = hour < 5 ? "Доброй ночи" : hour < 12 ? "Доброе утро" : hour < 18 ? "Добрый день" : "Добрый вечер"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = store.timeZone
        formatter.dateFormat = "EEEE, d MMMM"
        return PageHeading(eyebrow: formatter.string(from: Date()), title: "\(greeting), \(store.preferences.name) ✳",
                           subtitle: "Всё важное о вашем дне — в одном месте.")
    }

    private func carbsMetric(_ entries: [DiaryRecord]) -> some View {
        let meals = entries.filter { $0.kind == .meal }
        let carbs = meals.reduce(0.0) { $0 + ($1.data.double("total_carbs") ?? 0) }
        // Insulin per day excludes basal insulin, which is shown separately.
        let doses = entries.filter { $0.kind == .insulin }
        let insulin = doses.filter { $0.data.string("insulin_type") != InsulinType.basal.rawValue }
        let basal = doses.filter { $0.data.string("insulin_type") == InsulinType.basal.rawValue }
        let units = insulin.reduce(0.0) { $0 + ($1.data.double("units") ?? 0) }
        let basalUnits = basal.reduce(0.0) { $0 + ($1.data.double("units") ?? 0) }
        return Card {
            Label("Углеводы сегодня", systemImage: "fork.knife").font(.subheadline).foregroundStyle(theme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(meals.isEmpty ? BolusFormat.dash : BolusFormat.decimal(carbs, 0)).font(.system(size: 34, weight: .bold)).foregroundStyle(theme.text)
                Text("г").foregroundStyle(theme.muted)
            }
            HStack {
                Text("Приёмов пищи: \(meals.count)")
                Spacer()
                Text(insulin.isEmpty ? "Инсулин: нет записей" : "Инсулин за день: \(BolusFormat.decimal(units)) ЕД")
            }
            .font(.caption).foregroundStyle(theme.muted)
            if !basal.isEmpty {
                Text("Базальный отдельно: \(BolusFormat.decimal(basalUnits)) ЕД — не входит в инсулин за день")
                    .font(.caption2).foregroundStyle(theme.muted)
            }
        }
    }

    private var chartCard: some View {
        let now = Date()
        let from = chartDays == 1 ? now.addingTimeInterval(-86400) : store.today.adding(days: -(chartDays - 1)).startOfDay(in: store.timeZone)
        let entries = store.entries(from: from, to: now.addingTimeInterval(EntryFactory.futureTolerance))
        let metrics = AnalyticsEngine.summarize(entries, days: max(chartDays, 1))
        return Card {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(chartDays == 1 ? "Глюкоза за 24 часа" : "История глюкозы").font(.headline).foregroundStyle(theme.text)
                    Text("Диапазон \(BolusFormat.decimal(3.9 * store.unit.factor, 1))–\(BolusFormat.decimal(10 * store.unit.factor, 0)) \(store.unit.label)")
                        .font(.caption2).foregroundStyle(theme.muted)
                }
                Spacer()
                Picker("Период", selection: $chartDays) {
                    Text("24 ч").tag(1)
                    Text("7 д").tag(7)
                    Text("14 д").tag(14)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
            GlucoseChartView(entries: entries, unit: store.unit)
            ChartLegend()
            Divider()
            HStack {
                summaryItem("В диапазоне", metrics.tir.map { BolusFormat.decimal($0, 0) + "%" } ?? BolusFormat.dash)
                Spacer()
                summaryItem("Средняя", BolusFormat.glucose(metrics.meanGlucose, unit: store.unit))
                Spacer()
                summaryItem("Записей", String(metrics.sampleSize))
            }
            Text("Проценты рассчитаны по записанным измерениям, это не время CGM в диапазоне.")
                .font(.caption2).foregroundStyle(theme.muted)
        }
    }

    private func summaryItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(theme.muted)
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(theme.text)
        }
    }

    private func eventsCard(_ entries: [DiaryRecord]) -> some View {
        let recent = Array(entries.sorted { $0.occurredAt > $1.occurredAt }.prefix(4))
        let cycleStarts = store.cycles().filter { $0.startDate == store.today }
        return Card {
            HStack {
                Text("События сегодня").font(.headline).foregroundStyle(theme.text)
                Text("\(entries.count)").font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                    .background(theme.mint).clipShape(Capsule()).foregroundStyle(theme.accent)
                Spacer()
            }
            ForEach(cycleStarts) { cycle in
                NavigationLink { CycleView() } label: { CycleDayRow(cycle: cycle) }.buttonStyle(.plain)
            }
            if recent.isEmpty && cycleStarts.isEmpty {
                EmptyState(action: { onAdd(.glucose) })
            } else {
                ForEach(recent) { entry in
                    Button { selected = entry } label: { EventRow(entry: entry, unit: store.unit, timeZone: store.timeZone) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    private var mascotCard: some View {
        let mascot = Mascot.named(store.preferences.mascotID)
        return Card {
            Label("На вашей стороне", systemImage: "leaf").font(.caption.weight(.semibold)).foregroundStyle(theme.accent)
            HStack(alignment: .center, spacing: 14) {
                MascotArt(id: mascot.id, size: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Забота начинается с маленьких шагов").font(.headline).foregroundStyle(theme.text)
                    Text("Одна запись — уже внимание к себе. Вы в своём ритме, и это хорошо.").font(.footnote).foregroundStyle(theme.muted)
                }
            }
            HStack {
                Text(mascot.id == "cat" ? "Ваш помощник Персик" : "Ваш маленький помощник — \(mascot.name.lowercased())")
                Spacer()
                Image(systemName: "heart")
            }
            .font(.caption).foregroundStyle(theme.muted)
        }
    }
}

struct GlucoseMetric: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.theme) private var theme
    let latest: DiaryRecord?
    let todayEntries: [DiaryRecord]
    let onAdd: () -> Void

    var body: some View {
        Card {
            Label("Последняя глюкоза", systemImage: "drop.fill").font(.subheadline).foregroundStyle(theme.muted)
            if let latest, let mmol = latest.data.double("value_mmol") {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(BolusFormat.glucose(mmol, unit: store.unit)).font(.system(size: 40, weight: .bold)).foregroundStyle(theme.text)
                    Text(GlucosePayload.trendArrows[latest.glucose?.trend ?? "unknown"] ?? "").font(.title2).foregroundStyle(theme.accent)
                    Text(store.unit.label).foregroundStyle(theme.muted)
                }
                HStack {
                    Text(mmol < 3.9 ? "Ниже диапазона" : mmol > 10 ? "Выше диапазона" : "В диапазоне")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(theme.mint).clipShape(Capsule()).foregroundStyle(theme.accent)
                    Spacer()
                    Text(latest.occurredAt.dateTime(store.timeZone) + " · вручную").font(.caption).foregroundStyle(theme.muted)
                }
                Sparkline(values: todayEntries.filter { $0.kind == .glucose }.suffix(15).compactMap { $0.data.double("value_mmol") })
                    .frame(height: 44)
            } else {
                Text(BolusFormat.dash).font(.system(size: 40, weight: .bold)).foregroundStyle(theme.text)
                Button("Добавить измерение", action: onAdd).font(.footnote.weight(.semibold))
            }
        }
    }
}

struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                guard values.count > 1 else { return }
                for (index, value) in values.enumerated() {
                    let x = proxy.size.width * CGFloat(index) / CGFloat(values.count - 1)
                    let y = proxy.size.height - proxy.size.height * CGFloat(min(value, 15) / 15)
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(BolusTheme.glucoseLine, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
    }
}

/// Active insulin, refreshed every 30 seconds (local computation, no network).
struct IOBMetric: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let _ = store.revision
            let iob = store.currentIOB(at: context.date)
            Card {
                Label("Активный инсулин", systemImage: "syringe.fill").font(.subheadline).foregroundStyle(theme.muted)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(BolusFormat.decimal(iob)).font(.system(size: 34, weight: .bold)).foregroundStyle(theme.text)
                    Text("ЕД").foregroundStyle(theme.muted)
                }
                HStack {
                    Text("IOB · сейчас · \(IOBEngine.modelVersion)")
                    Spacer()
                    Text(store.activeProfile().map { "\(BolusFormat.number($0.settings.insulinActionDuration)) ч DIA" } ?? "DIA не задана")
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(theme.border))
                }
                .font(.caption2).foregroundStyle(theme.muted)
                ProgressView(value: min((iob ?? 0) / 10, 1)).tint(theme.accent)
                if iob == nil { Notice(text: "В записях инсулина есть некорректная DIA — проверьте дневник.", style: .error) }
            }
        }
    }
}

struct ShortcutCard: View {
    @Environment(\.theme) private var theme
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(theme.accent)
                .frame(width: 44, height: 44).background(theme.mint).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(theme.text)
                Text(subtitle).font(.caption).foregroundStyle(theme.muted)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(theme.accent)
        }
        .padding(16)
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.radius, style: .continuous).stroke(theme.border))
    }
}

struct CycleShortcut: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        let latest = store.latestCycle()
        let status = latest?.status(today: store.today)
        let length = status?.cycleLength ?? 28
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "moon").font(.title3).foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ВАШ ЦИКЛ").font(.caption2.weight(.semibold)).foregroundStyle(theme.muted)
                    Text(status.map { "День \($0.day)" } ?? "В вашем ритме").font(.headline).foregroundStyle(theme.text)
                    Text(status?.label ?? "Добавить начало цикла").font(.caption).foregroundStyle(theme.muted)
                    if let latest {
                        Text("Начало: \(latest.startDate.title("d MMMM yyyy"))").font(.caption).foregroundStyle(theme.muted)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(theme.accent)
            }
            HStack(spacing: 3) {
                ForEach(0..<min(length, 45), id: \.self) { index in
                    Capsule().fill(dayColor(index, currentDay: status?.day)).frame(height: 6)
                }
            }
            Text("Расчётная фаза · каждый цикл индивидуален · фаза не меняет дозу").font(.caption2).foregroundStyle(theme.muted)
        }
        .padding(16)
        .modifier(CardBackground())
    }

    private func dayColor(_ index: Int, currentDay: Int?) -> Color {
        if index < 5 { return BolusTheme.below }
        if let currentDay, index == currentDay - 1 { return theme.accent }
        return theme.border
    }
}

struct CardBackground: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
        .background(theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: theme.radius, style: .continuous).stroke(theme.border))
    }
}
