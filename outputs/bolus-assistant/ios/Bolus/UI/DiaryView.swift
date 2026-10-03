import SwiftUI

enum DiaryFilter: String, CaseIterable, Identifiable {
    case all, glucose, meal, insulin, activity, note
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Все"
        case .glucose: return "Глюкоза"
        case .meal: return "Еда"
        case .insulin: return "Инсулин"
        case .activity: return "Активность"
        case .note: return "Заметки"
        }
    }

    func matches(_ kind: EntryKind) -> Bool {
        switch self {
        case .all: return true
        case .glucose: return kind == .glucose
        case .meal: return kind == .meal
        case .insulin: return kind == .insulin
        case .activity: return kind == .activity || kind == .activitySummary
        case .note: return kind == .note
        }
    }
}

struct DiaryView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.theme) private var theme
    let onAdd: () -> Void
    @State private var day: LocalDate?
    @State private var filter: DiaryFilter = .all
    @State private var selected: DiaryRecord?

    var body: some View {
        let _ = store.revision
        let current = day ?? store.today
        let rows = store.entries(on: current).filter { filter.matches($0.kind) }.sorted { $0.occurredAt > $1.occurredAt }
        Screen {
            PageHeading(title: "Ваш дневник", subtitle: "Маленькие наблюдения складываются в большую картину.")
            Card {
                HStack {
                    Button { day = current.adding(days: -1) } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Предыдущий день")
                    Spacer()
                    DatePicker("Дата", selection: dateBinding(current), in: ...Date(), displayedComponents: .date)
                        .labelsHidden()
                        .environment(\.locale, Locale(identifier: "ru_RU"))
                    Spacer()
                    Button { day = current.adding(days: 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(current >= store.today)
                        .accessibilityLabel("Следующий день")
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(DiaryFilter.allCases) { item in
                            Button { filter = item } label: {
                                Text(item.title).font(.footnote)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(filter == item ? theme.mint : Color.clear)
                                    .foregroundStyle(filter == item ? theme.accent : theme.muted)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if rows.isEmpty {
                    EmptyState(action: onAdd)
                } else {
                    ForEach(rows) { entry in
                        Button { selected = entry } label: { EventRow(entry: entry, unit: store.unit, timeZone: store.timeZone) }
                            .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
            NavigationLink { HealthSyncView() } label: {
                ShortcutCard(icon: "heart.fill", title: "Импорт из «Здоровья»", subtitle: "Тренировки и дневная активность из HealthKit")
            }
        }
        .navigationTitle("Дневник")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onAdd) { Image(systemName: "plus.circle.fill") }.accessibilityLabel("Добавить запись")
            }
        }
        .sheet(item: $selected) { entry in
            NavigationStack { EntryDetailView(entry: entry) }.environment(\.theme, theme)
        }
    }

    private func dateBinding(_ current: LocalDate) -> Binding<Date> {
        Binding(get: { current.startOfDay(in: store.timeZone).addingTimeInterval(12 * 3600) },
                set: { day = LocalDate(date: $0, timeZone: store.timeZone) })
    }
}

struct EntryDetailView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let entry: DiaryRecord
    @State private var confirmDelete = false
    @State private var error: String?

    var body: some View {
        Screen {
            Card {
                EventRow(entry: entry, unit: store.unit, timeZone: store.timeZone)
                Text(entry.occurredAt.dateTime(store.timeZone)).font(.footnote).foregroundStyle(theme.muted)
                details
                if !entry.noteText.isEmpty && entry.kind != .note {
                    Text(entry.noteText).font(.footnote).foregroundStyle(theme.text)
                }
            }
            if entry.kind == .meal {
                NavigationLink { BolusView(mealID: entry.id) } label: {
                    Label("Рассчитать болюс для этой еды", systemImage: "function").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
            }
            if let error { Notice(text: error, style: .error) }
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("Удалить запись", systemImage: "trash").frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle(fullWidth: true))
            Text("Удаление инсулина изменит IOB. Исторический расчёт болюса остаётся в истории без изменений.")
                .font(.caption).foregroundStyle(theme.muted)
        }
        .navigationTitle("Запись в дневнике")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        .confirmationDialog("Удалить запись?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                do {
                    try store.deleteEntry(id: entry.id)
                    dismiss()
                } catch {
                    self.error = error.localizedDescription
                }
            }
        } message: {
            Text("Запись исчезнет из дневника и аналитики.")
        }
    }

    @ViewBuilder private var details: some View {
        switch entry.kind {
        case .glucose:
            if let glucose = entry.glucose {
                DataRow(label: "Введено", value: "\(BolusFormat.decimal(glucose.value)) \(glucose.unit.label)")
                DataRow(label: "Источник", value: glucose.source == "manual" ? "Вручную" : glucose.source)
            }
        case .insulin:
            if let insulin = entry.insulin {
                DataRow(label: "Доза", value: BolusFormat.units(insulin.units))
                DataRow(label: "Тип", value: insulin.insulinType == .rapid ? "Быстрый" : "Базальный")
                DataRow(label: "Назначение", value: insulin.purpose.label)
                if let dia = insulin.dia { DataRow(label: "DIA на момент введения", value: "\(BolusFormat.number(dia)) ч") }
                if insulin.relatedBolusCalculationID != nil { DataRow(label: "Источник", value: "Подтверждение расчёта болюса") }
            }
        case .meal:
            if let meal = entry.meal {
                DataRow(label: "Углеводы", value: "\(BolusFormat.decimal(meal.totalCarbs)) г")
                DataRow(label: "Белки / жиры", value: "\(BolusFormat.decimal(meal.totalProtein)) / \(BolusFormat.decimal(meal.totalFat)) г")
                DataRow(label: "Энергия", value: "\(BolusFormat.decimal(meal.totalCalories, 0)) ккал")
                ForEach(Array(meal.items.enumerated()), id: \.offset) { _, item in
                    Text("\(item.nameSnapshot) · \(BolusFormat.decimal(item.unit == .ml ? item.amount : (item.grams ?? item.amount))) \(item.unit == .ml ? "мл" : "г") · \(BolusFormat.decimal(item.carbs)) г углеводов")
                        .font(.caption).foregroundStyle(theme.muted)
                }
            }
        case .activity:
            if let activity = entry.activity {
                DataRow(label: "Длительность", value: "\(BolusFormat.decimal(activity.durationMinutes, 0)) мин")
                DataRow(label: "Источник", value: activity.isFromAppleHealth ? "Apple «Здоровье»" : "Вручную")
                if let energy = activity.activeEnergy { DataRow(label: "Активная энергия", value: "\(BolusFormat.decimal(energy, 0)) ккал") }
                if let distance = activity.distanceKm { DataRow(label: "Дистанция", value: "\(BolusFormat.decimal(distance)) км") }
            }
        case .activitySummary:
            if let summary = entry.activitySummary {
                if let steps = summary.steps { DataRow(label: "Шаги", value: BolusFormat.decimal(steps, 0)) }
                if let minutes = summary.exerciseMinutes { DataRow(label: "Упражнения", value: "\(BolusFormat.decimal(minutes)) мин") }
                if let energy = summary.activeEnergy { DataRow(label: "Активная энергия", value: "\(BolusFormat.decimal(energy)) ккал") }
                if let distance = summary.distanceKm { DataRow(label: "Ходьба и бег", value: "\(BolusFormat.decimal(distance)) км") }
            }
        case .note:
            Text(entry.noteText).foregroundStyle(theme.text)
        }
    }
}
