import SwiftUI

/// HealthKit → SwiftData. Reading happens on the device; nothing is sent anywhere.
struct HealthSyncView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var days = 30
    @State private var busy = false
    @State private var payload: HealthPayload?
    @State private var error: String?
    @State private var message: String?
    private let reader = HealthReader()

    var body: some View {
        Screen {
            PageHeading(title: "Apple «Здоровье»", subtitle: "Тренировки и активность — часть вашей истории.")
            Card {
                Label("Активность рядом с дневником", systemImage: "heart.fill").font(.headline).foregroundStyle(.pink)
                Text("Читаем только разрешённые тренировки, шаги, активную энергию, минуты упражнений и дистанцию ходьбы/бега.")
                    .font(.footnote).foregroundStyle(theme.text)
                Text("Данные сохраняются в локальный дневник этого iPhone. Ничего не записываем в «Здоровье» и никуда не отправляем. Работает без интернета.")
                    .font(.caption).foregroundStyle(theme.muted)
            }
            Card {
                Picker("Период", selection: $days) {
                    Text("7 дней").tag(7)
                    Text("30 дней").tag(30)
                    Text("90 дней").tag(90)
                }
                .pickerStyle(.segmented)
                .disabled(busy)
                Button { Task { await prepare() } } label: {
                    if busy { ProgressView("Обрабатываем…") } else { Text("Разрешить чтение и подготовить данные") }
                }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                .disabled(busy || !HealthReader.isAvailable)
                if !HealthReader.isAvailable { Notice(text: "Apple «Здоровье» недоступно на этом устройстве.", style: .error) }
                if let error { Notice(text: error, style: .error) }
            }
            if let payload {
                Card {
                    SectionTitle(title: "Перед сохранением")
                    DataRow(label: "Тренировки", value: String(payload.workouts.count))
                    DataRow(label: "Дни активности", value: String(payload.days.count))
                    DataRow(label: "Часовой пояс", value: payload.timezone)
                    Text("Нет данных — не обязательно нет активности: часть доступа могла быть не разрешена. Изменить доступ можно в «Здоровье».")
                        .font(.caption).foregroundStyle(theme.muted)
                    Button("Сохранить в мой дневник") { save(payload) }
                        .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                        .disabled(busy || (payload.workouts.isEmpty && payload.days.isEmpty))
                }
            }
            if let message { Notice(text: message, style: .success) }
            Text("Повторная синхронизация обновляет записи по UUID тренировки и по дате сводки и не создаёт копий. Удалённые в «Здоровье» записи удаляйте из дневника отдельно. Активность не меняет дозу и IOB.")
                .font(.caption).foregroundStyle(theme.muted)
        }
        .navigationTitle("Apple «Здоровье»")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: days) { _, _ in payload = nil; message = nil }
    }

    private func prepare() async {
        busy = true
        error = nil
        payload = nil
        message = nil
        defer { busy = false }
        do {
            payload = try await reader.read(days: days, timeZone: store.timeZone)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(_ data: HealthPayload) {
        error = nil
        do {
            let plan = try store.applyHealth(data)
            message = "Добавлено: \(plan.inserted). Обновлено: \(plan.updated). Без изменений: \(plan.unchanged)."
            payload = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
