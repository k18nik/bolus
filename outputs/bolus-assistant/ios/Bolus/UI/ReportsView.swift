import SwiftUI
import PDFKit

struct ReportsView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var type: ReportType = .doctor
    @State private var format: ReportFormat = .pdf
    @State private var days = 30
    @State private var customFrom = Date().addingTimeInterval(-29 * 86400)
    @State private var customTo = Date()
    @State private var graphs = true
    @State private var nutrition = true
    @State private var cycle = true
    @State private var shared: SharedFile?
    @State private var preview: SharedFile?
    @State private var error: String?
    @State private var busy = false
    @State private var files: [URL] = []

    var body: some View {
        Screen {
            PageHeading(title: "Экспорт и отчёты", subtitle: "Файлы создаются на iPhone без сервера и интернета.")
            Card {
                SectionTitle(title: "Создать отчёт", systemImage: "doc.text")
                Picker("Тип отчёта", selection: $type) {
                    ForEach(ReportType.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Период", selection: $days) {
                    Text("Последние 7 дней").tag(7)
                    Text("Последние 14 дней").tag(14)
                    Text("Последние 30 дней").tag(30)
                    Text("Последние 90 дней").tag(90)
                    Text("Выбрать даты").tag(0)
                }
                if days == 0 {
                    DatePicker("С", selection: $customFrom, in: ...customTo, displayedComponents: .date)
                    DatePicker("По", selection: $customTo, in: customFrom...Date(), displayedComponents: .date)
                }
                Picker("Формат", selection: $format) {
                    ForEach(ReportFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if format == .json {
                    Notice(text: "JSON — полная резервная копия всех данных за всё время (schemaVersion \(BackupDocument.currentSchemaVersion)), независимо от периода.")
                } else {
                    if format == .pdf { Toggle("Включить графики", isOn: $graphs) }
                    Toggle("Включить питание", isOn: $nutrition)
                    Toggle("Включить цикл", isOn: $cycle)
                }
                if let error { Notice(text: error, style: .error) }
                Button(action: generate) {
                    if busy { ProgressView() } else { Label("Создать и поделиться", systemImage: "square.and.arrow.up") }
                }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                .disabled(busy)
            }
            .environment(\.locale, Locale(identifier: "ru_RU"))
            Card {
                SectionTitle(title: "Созданные файлы", systemImage: "folder")
                if files.isEmpty {
                    Text("Ваш первый отчёт впереди. Готовый файл появится здесь.").font(.footnote).foregroundStyle(theme.muted)
                }
                ForEach(files, id: \.self) { url in
                    HStack {
                        Image(systemName: url.pathExtension == "pdf" ? "doc.richtext" : "doc").foregroundStyle(theme.accent)
                        Text(url.lastPathComponent).font(.footnote).foregroundStyle(theme.text).lineLimit(2)
                        Spacer()
                        if url.pathExtension == "pdf" {
                            Button { preview = SharedFile(url: url) } label: { Image(systemName: "eye") }.buttonStyle(.plain)
                        }
                        Button { shared = SharedFile(url: url) } label: { Image(systemName: "square.and.arrow.up") }.buttonStyle(.plain)
                        Button {
                            ReportService.delete(url)
                            files = ReportService.recentFiles()
                        } label: { Image(systemName: "trash") }.buttonStyle(.plain)
                    }
                    .foregroundStyle(theme.accent)
                }
                Text("Файлы хранятся во временной папке приложения; поделитесь ими, чтобы сохранить.").font(.caption2).foregroundStyle(theme.muted)
            }
            Notice(text: "Метрики отчёта рассчитываются детерминированно на устройстве. AI-резюме не включается. Отчёт описывает наблюдения и не ставит диагноз.")
        }
        .navigationTitle("Отчёты")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { files = ReportService.recentFiles() }
        .sheet(item: $shared) { file in ActivityView(items: [file.url]) }
        .sheet(item: $preview) { file in
            NavigationStack {
                PDFPreview(url: file.url)
                    .navigationTitle(file.url.lastPathComponent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { preview = nil } } }
            }
        }
    }

    private func generate() {
        error = nil
        busy = true
        defer { busy = false }
        do {
            let today = store.today
            let (from, to): (LocalDate, LocalDate) = days == 0
                ? (LocalDate(date: customFrom, timeZone: store.timeZone), LocalDate(date: customTo, timeZone: store.timeZone))
                : ReportOptions.period(days: days, endingAt: today)
            let options = ReportOptions(type: type, format: format, from: from, to: to, includeGraphs: graphs,
                                        includeNutrition: nutrition, includeCycle: cycle)
            let url = try ReportService.generate(options, store: store)
            files = ReportService.recentFiles()
            shared = SharedFile(url: url)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PDFPreview: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}
