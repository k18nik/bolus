import SwiftUI

struct CycleView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var month: LocalDate?
    @State private var showForm = false
    @State private var editing: CycleRecord?

    var body: some View {
        let _ = store.revision
        let cycles = store.cycles()
        let latest = store.latestCycle()
        let status = latest?.status(today: store.today)
        Screen {
            PageHeading(title: "В вашем ритме", subtitle: "Каждый цикл индивидуален. Узнавайте свой.")
            Card {
                Image(systemName: "moon.stars").font(.largeTitle).foregroundStyle(theme.accent)
                Text("ВАШ ЦИКЛ").font(.caption2.weight(.semibold)).foregroundStyle(theme.muted)
                Text(status.map { "День \($0.day)" } ?? "Узнавайте свой ритм").font(.title.weight(.bold)).foregroundStyle(theme.text)
                Text(status?.label ?? "Начните с первого дня менструации").font(.headline).foregroundStyle(theme.accent)
                Text("Фазы — приблизительный ориентир. Универсальные коэффициенты к инсулину не применяются: фаза никогда не меняет дозу.")
                    .font(.footnote).foregroundStyle(theme.muted)
                Button { showForm = true } label: { Label("Отметить начало цикла", systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle())
                if let latest, let status {
                    DataRow(label: "Начало цикла", value: latest.startDate.title("d MMMM yyyy"))
                    DataRow(label: "Обычная длина", value: "\(latest.cycleLength) дней")
                    DataRow(label: status.estimated ? "Расчётная овуляция" : "Фактическая овуляция", value: status.predictedOvulationDate.title("d MMMM"))
                }
            }
            calendar(latest: latest, status: status)
            Card {
                SectionTitle(title: "История циклов")
                if cycles.isEmpty {
                    Text("Пока нет сохранённых циклов").font(.footnote).foregroundStyle(theme.muted)
                }
                ForEach(cycles) { cycle in
                    Button { editing = cycle } label: {
                        HStack {
                            Text(cycle.startDate.title("d MMMM yyyy")).foregroundStyle(theme.text)
                            Spacer()
                            Text("\(cycle.cycleLength) дней").foregroundStyle(theme.muted)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(theme.muted)
                        }
                        .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Цикл")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showForm) { NavigationStack { CycleForm(cycle: nil) }.environment(\.theme, theme) }
        .sheet(item: $editing) { cycle in NavigationStack { CycleForm(cycle: cycle) }.environment(\.theme, theme) }
    }

    private func calendar(latest: CycleRecord?, status: CycleStatus?) -> some View {
        let today = store.today
        let shown = month ?? LocalDate(year: today.year, month: today.month, day: 1)!
        let first = LocalDate(year: shown.year, month: shown.month, day: 1)!
        let count = LocalDate.daysInMonth(year: shown.year, month: shown.month)
        let padding = first.weekdayMondayFirst
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return Card {
            HStack {
                Button { month = first.adding(days: -1).firstOfMonth } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("Предыдущий месяц")
                Spacer()
                Text(first.title("LLLL yyyy").capitalized).font(.headline).foregroundStyle(theme.text)
                Spacer()
                Button { month = first.adding(days: count).firstOfMonth } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("Следующий месяц")
            }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"], id: \.self) { Text($0).font(.caption2).foregroundStyle(theme.muted) }
                ForEach(0..<padding, id: \.self) { _ in Color.clear.frame(height: 32) }
                ForEach(1...count, id: \.self) { day in
                    let date = LocalDate(year: shown.year, month: shown.month, day: day)!
                    Text("\(day)")
                        .font(.footnote)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(background(date, latest: latest, status: status))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(date == today ? theme.accent : Color.clear, lineWidth: 1.5))
                        .foregroundStyle(theme.text)
                }
            }
            HStack(spacing: 14) {
                legend(BolusTheme.below.opacity(0.6), "Менструация · расчёт")
                legend(theme.accent.opacity(0.3), "Предполагаемая овуляция")
            }
        }
    }

    private func background(_ date: LocalDate, latest: CycleRecord?, status: CycleStatus?) -> Color {
        guard let latest else { return .clear }
        let day = date.days(since: latest.startDate) + 1
        if day >= 1 && day <= CycleEngine.menstrualDays { return BolusTheme.below.opacity(0.6) }
        if let status, date == status.predictedOvulationDate { return theme.accent.opacity(0.3) }
        return .clear
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(.caption2).foregroundStyle(theme.muted)
        }
    }
}

extension LocalDate {
    var firstOfMonth: LocalDate { LocalDate(year: year, month: month, day: 1)! }
}

struct CycleForm: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let cycle: CycleRecord?
    @State private var start = Date()
    @State private var length = "28"
    @State private var hasEnd = false
    @State private var end = Date()
    @State private var hasOvulation = false
    @State private var ovulation = Date()
    @State private var error: String?
    @State private var loaded = false
    @State private var confirmDelete = false

    var body: some View {
        Screen {
            Card {
                DatePicker("Первый день менструации", selection: $start, in: ...Date(), displayedComponents: .date)
                NumberField(title: "Обычная длина цикла", text: $length, unit: "дней")
                if cycle != nil {
                    Toggle("Дата окончания", isOn: $hasEnd)
                    if hasEnd { DatePicker("Окончание", selection: $end, displayedComponents: .date) }
                    Toggle("Фактическая овуляция", isOn: $hasOvulation)
                    if hasOvulation { DatePicker("Овуляция", selection: $ovulation, displayedComponents: .date) }
                }
                Text("Фазы рассчитываются приблизительно. Данные цикла не меняют дозу инсулина.").font(.caption).foregroundStyle(theme.muted)
            }
            .environment(\.locale, Locale(identifier: "ru_RU"))
            if let error { Notice(text: error, style: .error) }
            Button("Сохранить", action: save).buttonStyle(PrimaryButtonStyle(fullWidth: true))
            if cycle != nil {
                Button(role: .destructive) { confirmDelete = true } label: { Text("Удалить цикл").frame(maxWidth: .infinity) }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
            }
        }
        .navigationTitle(cycle == nil ? "Начало цикла" : "Цикл")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        .onAppear(perform: load)
        .confirmationDialog("Удалить цикл?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                if let cycle { try? store.deleteCycle(id: cycle.id) }
                dismiss()
            }
        }
    }

    private func load() {
        guard !loaded, let cycle else { return }
        loaded = true
        let zone = store.timeZone
        start = cycle.startDate.startOfDay(in: zone).addingTimeInterval(12 * 3600)
        length = String(cycle.cycleLength)
        if let endDate = cycle.endDate { hasEnd = true; end = endDate.startOfDay(in: zone).addingTimeInterval(12 * 3600) }
        if let date = cycle.actualOvulationDate { hasOvulation = true; ovulation = date.startOfDay(in: zone).addingTimeInterval(12 * 3600) }
    }

    private func save() {
        error = nil
        do {
            guard let days = BolusFormat.parse(length).flatMap({ Int(exactly: $0) }) else { throw BolusError.validation("Длина цикла: целое число дней") }
            let zone = store.timeZone
            let startDate = LocalDate(date: start, timeZone: zone)
            if var record = cycle {
                record.startDate = startDate
                record.cycleLength = days
                record.endDate = hasEnd ? LocalDate(date: end, timeZone: zone) : nil
                record.actualOvulationDate = hasOvulation ? LocalDate(date: ovulation, timeZone: zone) : nil
                try store.updateCycle(record)
            } else {
                try store.saveCycle(start: startDate, length: days)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
