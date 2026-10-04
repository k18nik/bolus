import SwiftUI

/// A meal line being corrected: the amount (or the carbs of a hand-typed line) is editable,
/// nutrients are rescaled from the saved snapshot.
struct EditableMealItem: Identifiable, Equatable {
    let id = UUID()
    let original: MealItem
    var text: String

    init(_ item: MealItem) {
        original = item
        text = BolusFormat.number(item.isManualCarbs ? item.carbs : item.amount)
    }

    var unitLabel: String {
        if original.isManualCarbs { return "г угл." }
        switch original.unit {
        case .g: return "г"
        case .ml: return "мл"
        case .serving: return "порц."
        }
    }

    var item: MealItem? {
        guard let number = BolusFormat.parse(text), number > 0 else { return nil }
        if original.isManualCarbs {
            var copy = original
            copy.carbs = number
            return copy
        }
        return original.rescaled(to: number)
    }
}

/// Corrections of a saved entry, opened from the entry card before «Удалить».
struct EntryEditView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let entry: DiaryRecord

    @State private var base: DiaryRecord?
    @State private var time = Date()
    @State private var value = ""
    @State private var note = ""
    @State private var name = ""
    @State private var mealType: MealType = .snack
    @State private var items: [EditableMealItem] = []
    @State private var minutes = ""
    @State private var intensity = "moderate"
    @State private var error: String?

    var body: some View {
        Screen {
            Card {
                DatePicker("Время", selection: $time, in: ...Date().addingTimeInterval(EntryFactory.futureTolerance))
                    .environment(\.locale, Locale(identifier: "ru_RU"))
                fields
            }
            if let error { Notice(text: error, style: .error) }
            Button("Сохранить изменения", action: save).buttonStyle(PrimaryButtonStyle(fullWidth: true))
            Text("Исправление сохраняется как новая версия записи и отмечается в журнале изменений. Данные остаются на этом iPhone.")
                .font(.caption).foregroundStyle(theme.muted)
        }
        .navigationTitle("Редактировать")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    @ViewBuilder private var fields: some View {
        switch entry.kind {
        case .glucose:
            NumberField(title: "Глюкоза, \(store.unit.label)", text: $value)
            noteField
        case .insulin:
            let payload = (base ?? entry).insulin
            DataRow(label: "Инсулин", value: insulinTitle(payload))
            NumberField(title: "Доза, ЕД", text: $value, unit: "шаг \(BolusFormat.number(payload?.doseIncrement ?? BolusEngine.legacyIncrement))")
            if payload?.relatedBolusCalculationID != nil {
                Text("Эта доза подтверждала расчёт болюса. Расчёт останется в истории без изменений, IOB будет учитывать исправленную дозу.")
                    .font(.caption).foregroundStyle(theme.muted)
            }
            noteField
        case .meal:
            LabeledField(title: "Название приёма пищи") { TextField("Приём пищи", text: $name) }
            Picker("Тип", selection: $mealType) {
                ForEach(MealType.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            ForEach(items) { line in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.original.nameSnapshot).font(.subheadline.weight(.semibold)).foregroundStyle(theme.text).lineLimit(1)
                        Text(line.item.map { "\(BolusFormat.decimal($0.carbs)) г угл. · \(BolusFormat.decimal($0.calories, 0)) ккал" } ?? "Укажите количество")
                            .font(.caption).foregroundStyle(theme.muted)
                    }
                    Spacer()
                    TextField("0", text: amountBinding(line.id))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.center)
                        .frame(width: 70)
                        .padding(6)
                        .background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text(line.unitLabel).font(.caption).foregroundStyle(theme.muted)
                    Button { items.removeAll { $0.id == line.id } } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.muted)
                        .accessibilityLabel("Убрать \(line.original.nameSnapshot)")
                }
                .padding(10)
                .background(theme.background)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            DataRow(label: "Всего углеводов", value: "\(BolusFormat.decimal(items.compactMap(\.item).reduce(0.0) { $0 + $1.carbs })) г")
            noteField
        case .activity:
            LabeledField(title: "Название активности") { TextField("Например, ходьба", text: $name) }
            NumberField(title: "Длительность", text: $minutes, unit: "мин")
            Picker("Интенсивность", selection: $intensity) {
                Text("Лёгкая").tag("low")
                Text("Умеренная").tag("moderate")
                Text("Высокая").tag("high")
            }
            .pickerStyle(.segmented)
            noteField
        case .note:
            TextField("Заметка", text: $note, axis: .vertical)
                .lineLimit(3...10)
                .padding(10)
                .background(theme.background)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .activitySummary:
            Text("Дневная сводка из «Здоровья» обновляется синхронизацией.").font(.footnote).foregroundStyle(theme.muted)
        }
    }

    private var noteField: some View {
        LabeledField(title: "Заметка · необязательно") { TextField("Комментарий", text: $note, axis: .vertical).lineLimit(1...5) }
    }

    private func insulinTitle(_ payload: InsulinPayload?) -> String {
        guard let payload else { return "" }
        let kind = payload.insulinType == .rapid ? "быстрый" : "базальный"
        return payload.insulinName.isEmpty ? kind.capitalized : "\(payload.insulinName) · \(kind)"
    }

    private func amountBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { items.first { $0.id == id }?.text ?? "" },
                set: { value in
                    if let index = items.firstIndex(where: { $0.id == id }) { items[index].text = value }
                })
    }

    private func load() {
        guard base == nil else { return }
        let record = store.entry(id: entry.id) ?? entry
        base = record
        time = record.occurredAt
        note = record.noteText
        switch record.kind {
        case .glucose:
            if let mmol = record.data.double("value_mmol") {
                value = BolusFormat.decimal(store.unit.fromMmol(mmol), store.unit == .mgdl ? 0 : 1)
            }
        case .insulin:
            value = record.insulin.map { BolusFormat.number($0.units) } ?? ""
        case .meal:
            if let meal = record.meal {
                name = meal.name
                mealType = meal.mealType
                items = meal.items.map(EditableMealItem.init)
            }
        case .activity:
            if let activity = record.activity {
                name = activity.name
                minutes = BolusFormat.number(activity.durationMinutes)
                intensity = ["low", "moderate", "high"].contains(activity.intensity) ? activity.intensity : "moderate"
            }
        case .note, .activitySummary:
            break
        }
    }

    private func save() {
        error = nil
        do {
            let original = base ?? entry
            let editor = store.editor()
            let updated: DiaryRecord
            switch original.kind {
            case .glucose:
                guard let number = BolusFormat.parse(value) else { throw BolusError.validation("Введите значение глюкозы") }
                updated = try editor.glucose(original, value: number, unit: store.unit, measuredAt: time, note: note)
            case .insulin:
                guard let units = BolusFormat.parse(value) else { throw BolusError.validation("Введите дозу") }
                updated = try editor.insulin(original, units: units, administeredAt: time, note: note,
                                             maxUnits: store.confirmationLimit(for: original))
            case .meal:
                let mealItems = items.compactMap(\.item)
                guard mealItems.count == items.count else { throw BolusError.validation("Укажите количество каждого продукта") }
                updated = try editor.meal(original, name: name, mealType: mealType, eatenAt: time, items: mealItems, note: note)
            case .activity:
                guard let number = BolusFormat.parse(minutes), let whole = Int(exactly: number) else {
                    throw BolusError.validation("Длительность указывается в целых минутах")
                }
                updated = try editor.activity(original, name: name, durationMinutes: whole, intensity: intensity, occurredAt: time, note: note)
            case .note:
                updated = try editor.note(original, text: note, occurredAt: time)
            case .activitySummary:
                throw BolusError.validation("Дневную сводку изменяет синхронизация с «Здоровьем»")
            }
            try store.updateEntry(updated)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
