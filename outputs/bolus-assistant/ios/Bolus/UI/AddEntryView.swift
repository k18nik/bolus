import SwiftUI

enum AddSection: String, CaseIterable, Identifiable {
    case glucose, meal, insulin, activity, cycle, note, bolus
    var id: String { rawValue }

    var title: String {
        switch self {
        case .glucose: return "Глюкоза"
        case .meal: return "Еда"
        case .insulin: return "Инсулин"
        case .activity: return "Активность"
        case .cycle: return "Цикл"
        case .note: return "Заметка"
        case .bolus: return "Болюс"
        }
    }

    var icon: String {
        switch self {
        case .glucose: return "drop.fill"
        case .meal: return "fork.knife"
        case .insulin: return "syringe.fill"
        case .activity: return "figure.walk"
        case .cycle: return "moon"
        case .note: return "note.text"
        case .bolus: return "function"
        }
    }
}

/// One scrollable page: every section is optional, filled sections are saved atomically.
struct AddEntryView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    var initialSection: AddSection = .glucose
    var initialFood: FoodRecord? = nil

    @State private var time = Date()
    @State private var glucose = ""
    @State private var mealName = "Приём пищи"
    @State private var mealType: MealType = .snack
    @State private var items: [PickedFood] = []
    @State private var carbs = ""
    @State private var rapid = ""
    @State private var basal = ""
    @State private var activity = ""
    @State private var minutes = ""
    @State private var intensity = "moderate"
    @State private var trackCycle = false
    @State private var cycleStart = Date()
    @State private var cycleLength = "28"
    @State private var note = ""
    @State private var error: String?
    @State private var saved: EntryFactory.BatchResult?
    @State private var appliedInitial = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Заполните только нужное. Все разделы на этой странице; запись работает без интернета.")
                        .font(.footnote).foregroundStyle(theme.muted)
                    shortcuts(proxy)
                    if let saved { savedCard(saved) }
                    if let error { Notice(text: error, style: .error) }
                    Card {
                        DatePicker("Дата и время записи", selection: $time, in: ...Date().addingTimeInterval(300))
                            .environment(\.locale, Locale(identifier: "ru_RU"))
                        Text("В часовом поясе \(store.timeZone.identifier)").font(.caption).foregroundStyle(theme.muted)
                    }
                    glucoseSection.id(AddSection.glucose)
                    mealSection.id(AddSection.meal)
                    insulinSection.id(AddSection.insulin)
                    activitySection.id(AddSection.activity)
                    cycleSection.id(AddSection.cycle)
                    noteSection.id(AddSection.note)
                    bolusSection.id(AddSection.bolus)
                    Button(action: save) { Text("Сохранить заполненное") }
                        .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                        .disabled(draftIsEmpty)
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(theme.background.ignoresSafeArea())
            .onAppear {
                guard !appliedInitial else { return }
                appliedInitial = true
                if let initialFood { items = [PickedFood(food: initialFood)] }
                if initialSection != .glucose {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { withAnimation { proxy.scrollTo(initialSection, anchor: .top) } }
                }
            }
        }
        .navigationTitle("Добавить запись")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Сохранить", action: save).disabled(draftIsEmpty) }
        }
    }

    private func shortcuts(_ proxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AddSection.allCases) { section in
                    Button { withAnimation { proxy.scrollTo(section, anchor: .top) } } label: {
                        Label(section.title, systemImage: section.icon).font(.footnote)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(theme.surface)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(theme.border))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
                }
            }
        }
    }

    private var profile: TherapyProfileRecord? { store.activeProfile() }

    private var glucoseSection: some View {
        Card {
            SectionTitle(title: "Глюкоза", systemImage: AddSection.glucose.icon)
            NumberField(title: "Глюкоза, \(store.unit.label)", text: $glucose, placeholder: "Можно оставить пустым")
        }
    }

    private var mealSection: some View {
        let picked = items.compactMap(\.item)
        let total = picked.reduce(0.0) { $0 + $1.carbs } + (BolusFormat.parse(carbs) ?? 0)
        return Card {
            SectionTitle(title: "Еда", systemImage: AddSection.meal.icon)
            LabeledField(title: "Название приёма пищи") { TextField("Приём пищи", text: $mealName) }
            Picker("Тип", selection: $mealType) {
                ForEach(MealType.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            FoodPicker(onPick: { items.append(PickedFood(food: $0)) })
            IngredientEditor(items: $items)
            NumberField(title: "Углеводы вручную · необязательно", text: $carbs, unit: "г", placeholder: "Необязательно")
            Text("Добавляются к выбранным продуктам. Остальные нутриенты для этой строки не указаны.").font(.caption).foregroundStyle(theme.muted)
            DataRow(label: "Всего углеводов", value: "\(BolusFormat.decimal(total)) г")
        }
    }

    private var insulinSection: some View {
        Card {
            SectionTitle(title: "Фактически введённый инсулин", systemImage: AddSection.insulin.icon)
            Text("Записывайте только уже введённый инсулин. Быстрый участвует в IOB, базальный учитывается отдельно.")
                .font(.caption).foregroundStyle(theme.muted)
            NumberField(title: "\(nonEmpty(profile?.settings.rapidInsulinName) ?? "Быстрый инсулин"), ЕД", text: $rapid,
                        unit: "шаг \(BolusFormat.number(profile?.settings.bolusIncrement ?? BolusEngine.legacyIncrement))", placeholder: "Необязательно")
            NumberField(title: "\(nonEmpty(profile?.settings.basalInsulinName) ?? "Базальный инсулин"), ЕД", text: $basal,
                        unit: "шаг \(BolusFormat.number(profile?.settings.basalIncrement ?? BolusEngine.legacyIncrement))", placeholder: "Необязательно")
            if profile == nil {
                Notice(text: "Для быстрого инсулина нужна DIA из профиля терапии. Базальный можно записать без профиля.")
            }
        }
    }

    private var activitySection: some View {
        Card {
            SectionTitle(title: "Активность", systemImage: AddSection.activity.icon)
            LabeledField(title: "Название активности") { TextField("Например, ходьба", text: $activity) }
            NumberField(title: "Длительность", text: $minutes, unit: "мин")
            Picker("Интенсивность", selection: $intensity) {
                Text("Лёгкая").tag("low")
                Text("Умеренная").tag("moderate")
                Text("Высокая").tag("high")
            }
            .pickerStyle(.segmented)
        }
    }

    private var cycleSection: some View {
        Card {
            SectionTitle(title: "Цикл", systemImage: AddSection.cycle.icon)
            Toggle("Отметить начало цикла", isOn: $trackCycle)
            if trackCycle {
                DatePicker("Первый день менструации", selection: $cycleStart, in: ...Date(), displayedComponents: .date)
                    .environment(\.locale, Locale(identifier: "ru_RU"))
                NumberField(title: "Обычная длина цикла", text: $cycleLength, unit: "дней")
            }
            Text("Фаза цикла не меняет дозу инсулина.").font(.caption).foregroundStyle(theme.muted)
        }
    }

    private var noteSection: some View {
        Card {
            SectionTitle(title: "Заметка", systemImage: AddSection.note.icon)
            TextField("Что хочется отметить?", text: $note, axis: .vertical)
                .lineLimit(3...8)
                .padding(10)
                .background(theme.background)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var bolusSection: some View {
        let picked = items.compactMap(\.item)
        let total = picked.reduce(0.0) { $0 + $1.carbs } + (BolusFormat.parse(carbs) ?? 0)
        return Card {
            SectionTitle(title: "Калькулятор болюса", systemImage: AddSection.bolus.icon)
            Text("Расчёт выполняется на iPhone по подтверждённому профилю, без интернета. Еду лучше сначала сохранить — тогда углеводы возьмутся из записи.")
                .font(.caption).foregroundStyle(theme.muted)
            NavigationLink {
                BolusView(prefillGlucose: BolusFormat.parse(glucose), prefillCarbs: total > 0 ? total : nil, prefillTime: glucose.isEmpty ? nil : time)
            } label: {
                Label("Открыть калькулятор", systemImage: "function").frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle(fullWidth: true))
        }
    }

    private func savedCard(_ result: EntryFactory.BatchResult) -> some View {
        Card {
            Notice(text: "Сохранено записей: \(result.count). Данные на устройстве.", style: .success)
            if result.meal != nil || result.glucose != nil {
                NavigationLink { BolusView(mealID: result.meal?.id) } label: {
                    Label("Рассчитать болюс", systemImage: "function").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
            }
        }
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    private var draftIsEmpty: Bool {
        [glucose, carbs, rapid, basal, minutes, activity, note].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            && items.isEmpty && !trackCycle
    }

    private func number(_ text: String, _ field: String) throws -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let value = BolusFormat.parse(trimmed) else { throw BolusError.validation("Проверьте число в поле «\(field)»") }
        return value
    }

    private func save() {
        error = nil
        do {
            let mealItems = items.compactMap(\.item)
            guard mealItems.count == items.count else { throw BolusError.validation("Укажите количество каждого продукта") }
            var minutesValue: Int?
            if let value = try number(minutes, "Длительность") {
                guard let whole = Int(exactly: value) else { throw BolusError.validation("Длительность указывается в целых минутах") }
                minutesValue = whole
            }
            var lengthValue = 28
            if trackCycle {
                guard let whole = Int(exactly: try number(cycleLength, "Длина цикла") ?? 28) else {
                    throw BolusError.validation("Длина цикла: целое число дней")
                }
                lengthValue = whole
            }
            let draft = EntryFactory.BatchDraft(
                occurredAt: time, glucose: try number(glucose, "Глюкоза"), glucoseUnit: store.unit, mealName: mealName, mealType: mealType,
                mealItems: mealItems, manualCarbs: try number(carbs, "Углеводы"), rapidUnits: try number(rapid, "Быстрый инсулин"),
                basalUnits: try number(basal, "Базальный инсулин"), activityName: activity, activityMinutes: minutesValue,
                activityIntensity: intensity, cycleStart: trackCycle ? LocalDate(date: cycleStart, timeZone: store.timeZone) : nil,
                cycleLength: lengthValue, note: note)
            saved = try store.saveBatch(draft)
            glucose = ""
            items = []
            carbs = ""
            rapid = ""
            basal = ""
            activity = ""
            minutes = ""
            trackCycle = false
            note = ""
            time = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
