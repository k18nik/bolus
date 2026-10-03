import SwiftUI

/// Deterministic bolus calculator. Works fully offline: profile, IOB and the engine are
/// local. AI is never consulted for the result.
struct BolusView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.theme) private var theme
    var mealID: UUID? = nil
    var prefillGlucose: Double? = nil
    var prefillCarbs: Double? = nil
    var prefillTime: Date? = nil

    @State private var glucose = ""
    @State private var carbs = ""
    @State private var measuredAt = Date()
    @State private var selectedMeal: UUID?
    @State private var saveGlucose = false
    @State private var result: BolusCalculationRecord?
    @State private var actual = ""
    @State private var administeredAt = Date()
    @State private var confirmedEntry: DiaryRecord?
    @State private var error: String?
    @State private var prepared = false

    var body: some View {
        let _ = store.revision
        let profile = store.activeProfile()
        Screen {
            PageHeading(title: "Рассчитать болюс", subtitle: "Расчёт по вашему подтверждённому профилю, на этом iPhone.")
            if let profile, profile.settings.confirmed {
                Notice(text: "Расчёт по профилю v\(profile.version) · \(profile.settings.rapidInsulinName.isEmpty ? "быстрый инсулин" : profile.settings.rapidInsulinName). Работает без интернета.",
                       systemImage: "checkmark.shield")
                if let result {
                    resultView(result, profile: profile)
                } else {
                    form(profile)
                }
            } else {
                Card {
                    Notice(text: "Сначала настройте и подтвердите ICR, ISF, цель, порог коррекции, DIA и максимальный болюс.")
                    NavigationLink { TherapyProfileForm() } label: { Text("Настроить профиль").frame(maxWidth: .infinity) }
                        .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                }
            }
        }
        .navigationTitle("Болюс")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: prepare)
    }

    // MARK: Parameters

    private func form(_ profile: TherapyProfileRecord) -> some View {
        let meals = store.recentMeals()
        let meal = selectedMeal.flatMap { id in meals.first { $0.id == id } ?? store.entry(id: id) }
        return Card {
            Picker("Еда", selection: $selectedMeal) {
                Text("Без сохранённой еды").tag(UUID?.none)
                ForEach(meals) { item in
                    Text("\(item.meal?.name ?? "Еда") · \(WallClock.hourMinute(item.occurredAt, timeZone: store.timeZone)) · \(BolusFormat.decimal(item.data.double("total_carbs"))) г")
                        .tag(UUID?.some(item.id))
                }
            }
            NumberField(title: "Глюкоза, \(store.unit.label)", text: $glucose)
            DatePicker("Время измерения", selection: $measuredAt, in: ...Date().addingTimeInterval(60))
                .environment(\.locale, Locale(identifier: "ru_RU"))
            if isManualGlucose { Toggle("Записать измерение в дневник", isOn: $saveGlucose) }
            if let meal {
                DataRow(label: "Углеводы из записи «\(meal.meal?.name ?? "Еда")»", value: "\(BolusFormat.decimal(meal.data.double("total_carbs"))) г")
                Text("Углеводы берутся из сохранённой записи еды.").font(.caption).foregroundStyle(theme.muted)
            } else {
                NumberField(title: "Углеводы", text: $carbs, unit: "г", placeholder: "0")
            }
            let s = profile.settings
            let segment = try? TherapySegments.select(s.segments, localTime: WallClock.hourMinute(Date(), timeZone: store.timeZone))
            Label("Профиль v\(profile.version) · DIA \(BolusFormat.number(s.insulinActionDuration)) ч · лимит \(BolusFormat.number(s.maxBolus)) ЕД · шаг \(BolusFormat.number(s.bolusIncrement)) ЕД",
                  systemImage: "clock")
                .font(.caption).foregroundStyle(theme.muted)
            if let segment {
                Text("Сейчас \(segment.startTime)–\(segment.endTime): ICR \(BolusFormat.number(segment.icr)) г/ЕД · ISF \(BolusFormat.number(segment.isf)) · цель \(BolusFormat.number(segment.target)) · коррекция выше \(BolusFormat.number(segment.correctAbove)) ммоль/л")
                    .font(.caption).foregroundStyle(theme.muted)
            }
            if let error { Notice(text: error, style: .error) }
            Button("Рассчитать", action: calculate).buttonStyle(PrimaryButtonStyle(fullWidth: true))
            Text("Глюкоза должна быть измерена не более 15 минут назад. Превышение максимального болюса блокирует расчёт, доза не уменьшается автоматически.")
                .font(.caption2).foregroundStyle(theme.muted)
        }
    }

    private var isManualGlucose: Bool {
        guard let value = BolusFormat.parse(glucose) else { return false }
        guard let latest = store.latestGlucose(), let mmol = latest.data.double("value_mmol") else { return true }
        return abs(store.unit.fromMmol(mmol) - value) > 0.0001 || abs(latest.occurredAt.timeIntervalSince(measuredAt)) > 60
    }

    // MARK: Result and confirmation

    private func resultView(_ record: BolusCalculationRecord, profile: TherapyProfileRecord) -> some View {
        let output = record.result
        let blocked = output?.calculationStatus != .ok
        return VStack(alignment: .leading, spacing: 16) {
            Card {
                Text(blocked ? "Расчёт заблокирован" : "Рассчитанный болюс").font(.subheadline).foregroundStyle(blocked ? BolusTheme.danger : theme.muted)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(blocked ? BolusFormat.dash : BolusFormat.decimal(output?.recommendedBolus))
                        .font(.system(size: 48, weight: .bold)).foregroundStyle(blocked ? BolusTheme.danger : theme.text)
                    Text("ЕД").foregroundStyle(theme.muted)
                }
                if let output {
                    DataRow(label: "Еда", value: "+" + BolusFormat.decimal(output.mealBolus, 2))
                    DataRow(label: "Коррекция", value: (output.correctionBolus >= 0 ? "+" : "") + BolusFormat.decimal(output.correctionBolus, 2))
                    DataRow(label: "Активный инсулин (IOB)", value: "−" + BolusFormat.decimal(output.iobAdjustment, 2))
                    if let unrounded = output.unroundedBolus {
                        DataRow(label: "До округления", value: BolusFormat.decimal(unrounded, 3) + " ЕД")
                    }
                    DataRow(label: "Итого · шаг \(BolusFormat.number(output.roundingIncrement ?? BolusEngine.legacyIncrement)) ЕД, округление вниз",
                            value: blocked ? BolusFormat.dash : BolusFormat.units(output.recommendedBolus))
                    ForEach(output.warnings, id: \.self) { warning in
                        Notice(text: SafetyLayer.message(warning), style: blocked ? .error : .info)
                    }
                }
                Text("\(record.algorithmVersion) · \(record.input?.rapidInsulinName ?? "быстрый инсулин") · IOB: \(record.input?.iobModel ?? IOBEngine.modelVersion)")
                    .font(.caption2).foregroundStyle(theme.muted)
            }
            if let confirmedEntry {
                Card {
                    Notice(text: "Фактическая доза \(BolusFormat.units(confirmedEntry.data.double("units"))) сохранена отдельно от расчёта.", style: .success)
                    DataRow(label: "IOB сейчас", value: BolusFormat.units(store.currentIOB()))
                }
            } else if !blocked {
                Card {
                    SectionTitle(title: "Фактически введено", systemImage: "syringe.fill")
                    NumberField(title: "Доза, ЕД", text: $actual, unit: "шаг \(BolusFormat.number(record.input?.bolusIncrement ?? BolusEngine.legacyIncrement))",
                                placeholder: BolusFormat.decimal(output?.recommendedBolus))
                    Text("Введите самостоятельно. Сохраняется отдельно от рекомендации; только фактическая доза входит в IOB.")
                        .font(.caption).foregroundStyle(theme.muted)
                    DatePicker("Время введения", selection: $administeredAt, in: record.calculatedAt.addingTimeInterval(-60)...Date().addingTimeInterval(60))
                        .environment(\.locale, Locale(identifier: "ru_RU"))
                    if let error { Notice(text: error, style: .error) }
                    Button("Сохранить фактическую дозу") { confirm(record) }.buttonStyle(PrimaryButtonStyle(fullWidth: true))
                }
            } else if let error {
                Notice(text: error, style: .error)
            }
            Button("Вернуться к параметрам") {
                result = nil
                confirmedEntry = nil
                actual = ""
                error = nil
            }
            .buttonStyle(SecondaryButtonStyle(fullWidth: true))
            NavigationLink { AIView(calculationID: record.id) } label: {
                Label("Объяснить расчёт с AI", systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle(fullWidth: true))
            Text("AI только объясняет уже выполненный расчёт и не влияет на дозу. Требует интернет и ваш ключ.")
                .font(.caption2).foregroundStyle(theme.muted)
        }
    }

    // MARK: Actions

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        if let mealID { selectedMeal = mealID }
        if let prefillGlucose {
            glucose = BolusFormat.decimal(prefillGlucose, 1)
            measuredAt = prefillTime ?? Date()
            saveGlucose = true
        } else if let latest = store.latestGlucose(), let mmol = latest.data.double("value_mmol") {
            glucose = BolusFormat.decimal(store.unit.fromMmol(mmol), 1)
            measuredAt = latest.occurredAt
        }
        if let prefillCarbs { carbs = BolusFormat.decimal(prefillCarbs, 2) }
        if mealID == nil, prefillCarbs == nil, let meal = store.recentMeals(hours: 1).first { selectedMeal = meal.id }
    }

    private func calculate() {
        error = nil
        do {
            let glucoseValue = BolusFormat.parse(glucose)
            if !glucose.trimmingCharacters(in: .whitespaces).isEmpty && glucoseValue == nil { throw BolusError.validation("Проверьте значение глюкозы") }
            let meal = selectedMeal.flatMap { store.entry(id: $0) }
            let carbsValue = carbs.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : (BolusFormat.parse(carbs) ?? .nan)
            if saveGlucose && isManualGlucose, let value = glucoseValue {
                let entry = try store.factory().glucose(value: value, unit: store.unit, measuredAt: measuredAt)
                try store.insert([entry])
            }
            let request = BolusWorkflow.Request(glucose: glucoseValue, unit: store.unit, carbs: carbsValue, measuredAt: measuredAt, meal: meal)
            result = try store.calculateBolus(request)
            administeredAt = Date()
            actual = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func confirm(_ record: BolusCalculationRecord) {
        error = nil
        do {
            guard let units = BolusFormat.parse(actual) else { throw BolusError.validation("Введите фактически введённую дозу") }
            confirmedEntry = try store.confirmBolus(calculationID: record.id, units: units, administeredAt: administeredAt)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
