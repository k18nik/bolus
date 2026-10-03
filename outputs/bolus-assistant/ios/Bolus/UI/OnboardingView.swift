import SwiftUI
import UniformTypeIdentifiers

/// First launch: no account and no server. Everything stays on this iPhone.
struct OnboardingView: View {
    @Environment(DiaryStore.self) private var store
    @State private var step = 0
    @State private var name = ""
    @State private var unit: GlucoseUnit = .mmol
    @State private var therapy = "MDI"
    @State private var rapidName = "Фиасп"
    @State private var basalName = "Тресиба"
    @State private var bolusStep = 1.0
    @State private var icr = ""
    @State private var isf = ""
    @State private var target = ""
    @State private var above = ""
    @State private var dia = ""
    @State private var maxBolus = ""
    @State private var trackCycle = false
    @State private var cycleStart = Date()
    @State private var mascot = "cat"
    @State private var themeID = "light"
    @State private var confirmed = false
    @State private var skipTherapy = false
    @State private var error: String?
    @State private var importing = false
    @State private var importBox: PlanBox?

    /// The onboarding previews the theme being chosen.
    private var theme: BolusTheme { BolusTheme.named(themeID) }

    private let titles = ["Добро пожаловать", "О вас", "Ваша терапия", "Углеводный коэффициент", "Чувствительность к инсулину",
                          "Цель и порог коррекции", "Время действия и лимит", "Отслеживание цикла", "Маленький помощник",
                          "Тема оформления", "Проверим параметры"]

    var body: some View {
        let preview = BolusTheme.named(themeID)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ProgressView(value: Double(step + 1), total: Double(titles.count)).tint(preview.accent)
                Text("Шаг \(min(step + 1, 10)) из 10\(step == 10 ? " · подтверждение" : "")").font(.caption).foregroundStyle(preview.muted)
                Text(titles[step]).font(.title2.weight(.bold)).foregroundStyle(preview.text)
                content
                if let error { Notice(text: error, style: .error) }
                HStack {
                    if step > 0 {
                        Button("Назад", action: back).buttonStyle(SecondaryButtonStyle())
                    }
                    Spacer()
                    Button(step == 10 ? "Открыть дневник" : "Продолжить", action: next)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(step == 10 && !skipTherapy && !confirmed)
                }
            }
            .padding(20)
        }
        .background(preview.background.ignoresSafeArea())
        .environment(\.theme, preview)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { result in readBackup(result) }
        .sheet(item: $importBox) { box in
            NavigationStack {
                ImportPreview(plan: box.plan, onApply: { applyImport(box.plan) }, onCancel: { importBox = nil })
            }
            .environment(\.theme, preview)
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0:
            VStack(spacing: 14) {
                MascotArt(id: "cat", size: 150)
                Text("Это ваше спокойное место для наблюдений. Настроим дневник под вас — без оценок и соревнований.")
                    .multilineTextAlignment(.center).foregroundStyle(theme.text)
                Notice(text: "Bolus работает полностью на iPhone: без регистрации, сервера и интернета. Интернет нужен только для поиска в каталогах еды и AI.",
                       systemImage: "lock.shield")
                Text("Для коэффициентов терапии используйте значения, согласованные с вашим специалистом. Их можно изменить позже.")
                    .font(.footnote).foregroundStyle(theme.muted)
                Button { importing = true } label: { Label("Перенести данные из резервной копии", systemImage: "square.and.arrow.down") }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                Text("Подходит JSON-экспорт прежнего сервера Bolus и копии этого приложения.").font(.caption).foregroundStyle(theme.muted)
            }
            .frame(maxWidth: .infinity)
        case 1:
            LabeledField(title: "Как вас зовут?") { TextField("Мой дневник", text: $name) }
            Picker("Единицы глюкозы", selection: $unit) {
                Text("ммоль/л").tag(GlucoseUnit.mmol)
                Text("мг/дл").tag(GlucoseUnit.mgdl)
            }
            .pickerStyle(.segmented)
        case 2:
            Picker("Как вы получаете инсулин?", selection: $therapy) {
                Text("Инъекции (MDI)").tag("MDI")
                Text("Помпа").tag("PUMP")
                Text("Другое").tag("OTHER")
            }
            .pickerStyle(.segmented)
            LabeledField(title: "Быстрый инсулин") { TextField("Фиасп", text: $rapidName) }
            LabeledField(title: "Базальный инсулин") { TextField("Тресиба", text: $basalName) }
            Picker("Шаг болюсного устройства", selection: $bolusStep) {
                ForEach(InsulinCatalog.bolusSteps, id: \.self) { Text("\(BolusFormat.number($0)) ЕД").tag($0) }
            }
            Toggle("Настроить терапию позже (калькулятор будет недоступен)", isOn: $skipTherapy).font(.footnote)
        case 3:
            NumberField(title: "ICR, г углеводов на 1 ЕД инсулина", text: $icr)
        case 4:
            NumberField(title: "ISF, снижение глюкозы на 1 ЕД, ммоль/л", text: $isf)
            Text("Введите значение в ммоль/л на ЕД, независимо от единиц дневника.").font(.caption).foregroundStyle(theme.muted)
        case 5:
            NumberField(title: "Целевая глюкоза, ммоль/л", text: $target)
            NumberField(title: "Коррекция только выше, ммоль/л", text: $above)
            Text("Порог коррекции — отдельный параметр, он не ниже цели.").font(.caption).foregroundStyle(theme.muted)
        case 6:
            NumberField(title: "DIA, часов (2–8)", text: $dia, unit: "ч")
            NumberField(title: "Максимальный болюс", text: $maxBolus, unit: "ЕД")
        case 7:
            Toggle("Хочу отслеживать менструальный цикл", isOn: $trackCycle)
            if trackCycle {
                DatePicker("Начало последней менструации", selection: $cycleStart, in: ...Date(), displayedComponents: .date)
                    .environment(\.locale, Locale(identifier: "ru_RU"))
                Text("Начальная длина цикла — 28 дней; её можно уточнить на экране цикла. Фаза не меняет дозу.").font(.caption).foregroundStyle(theme.muted)
            }
        case 8:
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(Mascot.all, id: \.id) { pet in
                    Button { mascot = pet.id } label: {
                        VStack {
                            MascotArt(id: pet.id, size: 56)
                            Text(pet.name).font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(8)
                        .background(mascot == pet.id ? theme.mint : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        case 9:
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(BolusTheme.all, id: \.id) { item in
                    Button { themeID = item.id } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 10).fill(item.swatch).frame(height: 44)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(item.border))
                            Text(item.name).font(.caption)
                        }
                        .padding(8)
                        .background(themeID == item.id ? theme.mint : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        default:
            Card {
                Text("Имя: \(name.isEmpty ? "Мой дневник" : name) · единицы: \(unit.label)").font(.footnote)
                if skipTherapy {
                    Text("Профиль терапии будет настроен позже. Дневник, аналитика и отчёты доступны сразу.").font(.footnote)
                } else {
                    Text("Терапия: \(therapy) · \(rapidName) / \(basalName) · шаг \(BolusFormat.number(bolusStep)) ЕД").font(.footnote)
                    Text("ICR: \(icr) г/ЕД · ISF: \(isf) ммоль/л/ЕД").font(.footnote)
                    Text("Цель: \(target) · коррекция выше: \(above) ммоль/л").font(.footnote)
                    Text("DIA: \(dia) ч · максимальный болюс: \(maxBolus) ЕД").font(.footnote)
                    Text("Период: 00:00–24:00. Временные сегменты можно добавить в профиле.").font(.caption).foregroundStyle(theme.muted)
                    Toggle("Я проверил(а) и подтверждаю параметры терапии.", isOn: $confirmed).font(.footnote)
                }
            }
        }
    }

    /// Going back from the cycle step skips the therapy steps that were skipped forward.
    private func back() {
        error = nil
        step = step == 7 && skipTherapy ? 2 : step - 1
    }

    private func next() {
        error = nil
        if step == 2 && skipTherapy {
            step = 7
            return
        }
        if step < 10 {
            step += 1
            return
        }
        finish()
    }

    private func finish() {
        do {
            if !skipTherapy {
                func value(_ text: String, _ field: String) throws -> Double {
                    guard let number = BolusFormat.parse(text) else { throw BolusError.validation("Заполните поле «\(field)»") }
                    return number
                }
                let segment = TherapySegment(startTime: "00:00", endTime: "24:00", icr: try value(icr, "ICR"), isf: try value(isf, "ISF"),
                                             target: try value(target, "Цель"), correctAbove: try value(above, "Коррекция выше"))
                let settings = TherapySettings(insulinTherapyType: therapy, rapidInsulinName: rapidName, basalInsulinName: basalName,
                                               bolusIncrement: bolusStep, basalIncrement: 1, maxBolus: try value(maxBolus, "Максимальный болюс"),
                                               insulinActionDuration: try value(dia, "DIA"), segments: [segment], confirmed: confirmed)
                try store.saveProfile(settings)
            }
            if trackCycle { try store.saveCycle(start: LocalDate(date: cycleStart, timeZone: store.timeZone), length: 28) }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            try store.updatePreferences {
                $0.name = trimmed.isEmpty ? "Мой дневник" : String(trimmed.prefix(80))
                $0.glucoseUnit = unit
                $0.mascotID = mascot
                $0.themeID = themeID
                $0.onboardingCompleted = true
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func readBackup(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            importBox = PlanBox(plan: try store.planImport(try Data(contentsOf: url)))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func applyImport(_ plan: BackupImportPlan) {
        do {
            try store.applyImport(plan)
            importBox = nil
            try store.updatePreferences { $0.onboardingCompleted = true }
        } catch {
            self.error = error.localizedDescription
            importBox = nil
        }
    }
}
