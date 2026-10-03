import SwiftUI

struct HealthSyncView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var days = 30
    @State private var busy = false
    @State private var payload: HealthPayload?
    @State private var destination: URL?
    @State private var accountName = ""
    @State private var error: String?
    @State private var message: String?
    private let reader = HealthReader()
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Активность рядом с дневником", systemImage: "heart.fill").font(.headline).foregroundStyle(.pink)
                    Text("Читаем только разрешённые тренировки, шаги, активную энергию, минуты упражнений и дистанцию ходьбы/бега.")
                    Text("Данные будут отправлены в ваш аккаунт на выбранном сервере после отдельного нажатия. Ничего не записываем в Apple «Здоровье».").font(.footnote)
                }
                Section("Подготовка") {
                    Picker("Период", selection: $days) { Text("7 дней").tag(7); Text("30 дней").tag(30); Text("90 дней").tag(90) }.disabled(busy)
                    Button("Разрешить чтение и подготовить данные") { Task { await prepare() } }.disabled(busy)
                    if busy { ProgressView("Обрабатываем…") }
                    if let error { Text(error).foregroundStyle(.red) }
                }
                if let payload, let destination {
                    Section("Перед отправкой") {
                        LabeledContent("Сервер", value: destination.absoluteString)
                        LabeledContent("Аккаунт", value: accountName)
                        LabeledContent("Тренировки", value: String(payload.workouts.count))
                        LabeledContent("Дни активности", value: String(payload.days.count))
                        Text("Нет данных — не обязательно нет активности: часть доступа могла быть не разрешена. Изменить доступ можно в Apple «Здоровье».").font(.footnote)
                        Button("Отправить в мой дневник") { Task { await sync(payload, destination) } }.disabled(busy || (payload.workouts.isEmpty && payload.days.isEmpty))
                    }
                }
                if let message { Section { Label(message, systemImage: "checkmark.circle").foregroundStyle(.green) } }
                Section {
                    Text("Повторная синхронизация обновляет записи по идентификатору. Удалённые из «Здоровья» записи нужно удалять из дневника отдельно. Автоматическая фоновая синхронизация не включена.").font(.footnote)
                }
            }
            .navigationTitle("Apple «Здоровье»")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Готово") { dismiss() }.disabled(busy) }
            .interactiveDismissDisabled(busy)
            .onChange(of: days) { _, _ in payload = nil; message = nil }
        }
    }
    @MainActor private func prepare() async {
        busy = true; error = nil; payload = nil; message = nil
        defer { busy = false }
        do {
            guard let server = model.server else { throw AppFailure(message: "Сначала укажите адрес сервера.") }
            let account = try await model.account(at: server)
            let data = try await reader.read(days: days, userID: account.id)
            destination = server; accountName = account.name; payload = data
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func sync(_ data: HealthPayload, _ server: URL) async {
        busy = true; error = nil; message = nil
        defer { busy = false }
        do {
            let result = try await model.sync(data, at: server)
            message = "Добавлено: \(result.inserted). Обновлено: \(result.updated). Без изменений: \(result.unchanged)."
            payload = nil; model.reload()
        } catch { self.error = error.localizedDescription }
    }
}
