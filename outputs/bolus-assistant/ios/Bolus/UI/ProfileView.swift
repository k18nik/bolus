import SwiftUI

struct ProfileView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var showHistory = false

    var body: some View {
        let _ = store.revision
        let profile = store.activeProfile()
        Screen {
            PageHeading(title: "Терапевтический профиль", subtitle: "Используйте параметры, согласованные с вашим специалистом.")
            Card {
                if let profile {
                    let s = profile.settings
                    Text("Версия \(profile.version) · подтверждён \(profile.validFrom.dateTime(store.timeZone))")
                        .font(.caption.weight(.semibold)).foregroundStyle(theme.accent)
                    DataRow(label: "Терапия", value: s.insulinTherapyType)
                    DataRow(label: "Быстрый инсулин", value: s.rapidInsulinName.isEmpty ? BolusFormat.dash : s.rapidInsulinName)
                    DataRow(label: "Базальный инсулин", value: s.basalInsulinName.isEmpty ? BolusFormat.dash : s.basalInsulinName)
                    DataRow(label: "Шаг болюса / базального", value: "\(BolusFormat.number(s.bolusIncrement)) / \(BolusFormat.number(s.basalIncrement)) ЕД")
                    DataRow(label: "Действие инсулина (DIA)", value: "\(BolusFormat.number(s.insulinActionDuration)) ч")
                    DataRow(label: "Максимальный болюс", value: "\(BolusFormat.number(s.maxBolus)) ЕД")
                    ForEach(s.segments, id: \.startTime) { segment in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(segment.startTime)–\(segment.endTime)").font(.footnote.weight(.semibold)).foregroundStyle(theme.text)
                            Text("ICR \(BolusFormat.number(segment.icr)) г/ЕД · ISF \(BolusFormat.number(segment.isf)) ммоль/л/ЕД · цель \(BolusFormat.number(segment.target)) · коррекция выше \(BolusFormat.number(segment.correctAbove))")
                                .font(.caption).foregroundStyle(theme.muted)
                        }
                    }
                } else {
                    Text("Введите параметры терапии, согласованные с вашим специалистом. Без профиля дневник работает, а калькулятор болюса недоступен.")
                        .font(.footnote).foregroundStyle(theme.muted)
                }
                NavigationLink { TherapyProfileForm() } label: {
                    Text(profile == nil ? "Настроить профиль" : "Изменить профиль (новая версия)").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                Button("История версий и расчётов") { showHistory = true }.font(.footnote)
            }
            Notice(text: "Изменение создаёт новую версию. Старые версии и прошлые расчёты не пересчитываются и не изменяются.")
        }
        .navigationTitle("Профиль терапии")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showHistory) { NavigationStack { HistoryView() }.environment(\.theme, theme) }
    }
}

struct HistoryView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Screen {
            Card {
                SectionTitle(title: "Профили")
                ForEach(store.profiles()) { profile in
                    DataRow(label: "Версия \(profile.version) · \(profile.validFrom.dateTime(store.timeZone))",
                            value: profile.isActive ? "Активна" : "Архив")
                }
            }
            Card {
                SectionTitle(title: "Расчёты болюса")
                let calculations = store.calculations()
                if calculations.isEmpty { Text("Расчётов пока нет").font(.footnote).foregroundStyle(theme.muted) }
                ForEach(calculations) { calculation in
                    let result = calculation.result
                    VStack(alignment: .leading, spacing: 2) {
                        Text(calculation.calculatedAt.dateTime(store.timeZone)).font(.footnote.weight(.semibold)).foregroundStyle(theme.text)
                        Text("Расчёт: \(result?.calculationStatus == .ok ? BolusFormat.units(result?.recommendedBolus) : "заблокирован") · факт: \(BolusFormat.units(calculation.actualBolus)) · \(calculation.algorithmVersion)")
                            .font(.caption).foregroundStyle(theme.muted)
                    }
                    Divider()
                }
            }
        }
        .navigationTitle("История")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
    }
}

struct SegmentDraft: Identifiable, Equatable {
    let id = UUID()
    var start = "00:00"
    var end = "24:00"
    var icr = ""
    var isf = ""
    var target = ""
    var correctAbove = ""

    init() {}

    init(_ segment: TherapySegment) {
        start = segment.startTime
        end = segment.endTime
        icr = BolusFormat.number(segment.icr)
        isf = BolusFormat.number(segment.isf)
        target = BolusFormat.number(segment.target)
        correctAbove = BolusFormat.number(segment.correctAbove)
    }

    func segment() throws -> TherapySegment {
        func value(_ text: String, _ name: String) throws -> Double {
            guard let number = BolusFormat.parse(text) else { throw BolusError.validation("Заполните \(name) для периода \(start)–\(end)") }
            return number
        }
        return TherapySegment(startTime: start, endTime: end, icr: try value(icr, "ICR"), isf: try value(isf, "ISF"),
                              target: try value(target, "цель"), correctAbove: try value(correctAbove, "порог коррекции"))
    }
}

/// New confirmed profile version (the previous one is archived unchanged).
struct TherapyProfileForm: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var diabetesType = "type1"
    @State private var therapyType = "MDI"
    @State private var rapidName = "Фиасп"
    @State private var basalName = "Тресиба"
    @State private var bolusStep = 1.0
    @State private var basalStep = 1.0
    @State private var dia = ""
    @State private var maxBolus = ""
    @State private var segments: [SegmentDraft] = [SegmentDraft()]
    @State private var confirmed = false
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        Screen {
            Card {
                Picker("Тип диабета", selection: $diabetesType) {
                    Text("1 тип").tag("type1")
                    Text("2 тип").tag("type2")
                    Text("Другой").tag("other")
                }
                Picker("Терапия", selection: $therapyType) {
                    Text("Инъекции (MDI)").tag("MDI")
                    Text("Помпа").tag("PUMP")
                    Text("Другая").tag("OTHER")
                }
                LabeledField(title: "Быстрый инсулин", hint: "Фиасп / Fiasp — инсулин аспарт, используется для болюса и IOB.") {
                    TextField("Название", text: $rapidName)
                }
                LabeledField(title: "Базальный инсулин", hint: "Тресиба / Tresiba — деглудек, учитывается отдельно от болюсного IOB.") {
                    TextField("Название", text: $basalName)
                }
                Picker("Шаг болюсного устройства", selection: $bolusStep) {
                    ForEach(InsulinCatalog.bolusSteps, id: \.self) { Text("\(BolusFormat.number($0)) ЕД").tag($0) }
                }
                Picker("Шаг базальной ручки", selection: $basalStep) {
                    ForEach(InsulinCatalog.basalSteps, id: \.self) { Text("\(BolusFormat.number($0)) ЕД").tag($0) }
                }
                NumberField(title: "DIA, часов (2–8)", text: $dia, unit: "ч")
                Text("Название препарата не меняет DIA автоматически.").font(.caption).foregroundStyle(theme.muted)
                NumberField(title: "Максимальный болюс", text: $maxBolus, unit: "ЕД")
            }
            HStack {
                Text("Периоды в течение суток").font(.headline).foregroundStyle(theme.text)
                Spacer()
                Button { addSegment() } label: { Label("Период", systemImage: "plus") }.font(.footnote)
            }
            Text("ISF, цель и порог — в ммоль/л, независимо от единиц дневника. Периоды должны покрывать 00:00–24:00 без разрывов.")
                .font(.caption).foregroundStyle(theme.muted)
            ForEach($segments) { $segment in
                Card {
                    HStack {
                        LabeledField(title: "С") { TextField("00:00", text: $segment.start).keyboardType(.numbersAndPunctuation) }
                        LabeledField(title: "До") { TextField("24:00", text: $segment.end).keyboardType(.numbersAndPunctuation) }
                    }
                    HStack {
                        NumberField(title: "ICR, г/ЕД", text: $segment.icr)
                        NumberField(title: "ISF", text: $segment.isf)
                    }
                    HStack {
                        NumberField(title: "Цель", text: $segment.target)
                        NumberField(title: "Коррекция выше", text: $segment.correctAbove)
                    }
                    if segments.count > 1 {
                        Button("Удалить период", role: .destructive) {
                            let id = segment.id
                            DispatchQueue.main.async { segments.removeAll { $0.id == id } }
                        }
                        .font(.footnote)
                    }
                }
            }
            Card {
                Text("Проверьте перед сохранением").font(.headline).foregroundStyle(theme.text)
                Text("DIA: \(dia.isEmpty ? "—" : dia) ч · максимум: \(maxBolus.isEmpty ? "—" : maxBolus) ЕД · периодов: \(segments.count) · шаг болюса: \(BolusFormat.number(bolusStep)) ЕД")
                    .font(.footnote).foregroundStyle(theme.muted)
                ForEach(segments) { s in
                    Text("\(s.start)–\(s.end): ICR \(s.icr.isEmpty ? "—" : s.icr), ISF \(s.isf.isEmpty ? "—" : s.isf), цель \(s.target.isEmpty ? "—" : s.target), коррекция выше \(s.correctAbove.isEmpty ? "—" : s.correctAbove)")
                        .font(.caption).foregroundStyle(theme.muted)
                }
                Toggle("Я проверил(а) параметры и подтверждаю новую версию профиля.", isOn: $confirmed).font(.footnote)
            }
            if let error { Notice(text: error, style: .error) }
            Button("Сохранить и подтвердить профиль", action: save)
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                .disabled(!confirmed)
        }
        .navigationTitle("Профиль терапии")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let profile = store.activeProfile() else { return }
        let s = profile.settings
        diabetesType = s.diabetesType
        therapyType = s.insulinTherapyType
        rapidName = s.rapidInsulinName
        basalName = s.basalInsulinName
        bolusStep = s.bolusIncrement
        basalStep = s.basalIncrement
        dia = BolusFormat.number(s.insulinActionDuration)
        maxBolus = BolusFormat.number(s.maxBolus)
        segments = s.segments.map(SegmentDraft.init)
    }

    private func addSegment() {
        var draft = SegmentDraft()
        draft.start = "18:00"
        draft.end = "24:00"
        segments.append(draft)
    }

    private func save() {
        error = nil
        do {
            guard let diaValue = BolusFormat.parse(dia) else { throw BolusError.validation("Укажите DIA") }
            guard let maxValue = BolusFormat.parse(maxBolus) else { throw BolusError.validation("Укажите максимальный болюс") }
            let settings = TherapySettings(diabetesType: diabetesType, insulinTherapyType: therapyType,
                                           rapidInsulinName: rapidName.trimmingCharacters(in: .whitespaces),
                                           basalInsulinName: basalName.trimmingCharacters(in: .whitespaces),
                                           bolusIncrement: bolusStep, basalIncrement: basalStep, maxBolus: maxValue,
                                           insulinActionDuration: diaValue, segments: try segments.map { try $0.segment() }, confirmed: confirmed)
            try store.saveProfile(settings)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
