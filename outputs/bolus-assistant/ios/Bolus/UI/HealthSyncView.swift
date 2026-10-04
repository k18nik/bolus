import SwiftUI

/// Direct link HealthKit → SwiftData. Reading happens on the device; nothing is sent anywhere.
struct HealthSyncView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(HealthSyncController.self) private var health
    @Environment(\.theme) private var theme
    @State private var days = 30
    @State private var switching = false

    var body: some View {
        let _ = store.revision
        Screen {
            PageHeading(title: "Apple «Здоровье»", subtitle: "Тренировки и активность — часть вашей истории.")
            Card {
                Label("Прямая связь со «Здоровьем»", systemImage: "heart.fill").font(.headline).foregroundStyle(.pink)
                Toggle("Синхронизировать автоматически", isOn: autoSync)
                    .tint(theme.accent)
                    .disabled(switching || !HealthReader.isAvailable)
                Text("Новые тренировки, шаги, активная энергия, минуты упражнений и дистанция сохраняются в дневник сами: при открытии приложения и когда в «Здоровье» появляются новые данные, в том числе в фоне. Ничего не записывается в «Здоровье» и никуда не отправляется, интернет не нужен.")
                    .font(.caption).foregroundStyle(theme.muted)
                if let last = store.preferences.healthLastSync {
                    DataRow(label: "Последняя синхронизация", value: last.dateTime(store.timeZone))
                }
                if health.isSyncing { ProgressView("Синхронизация…").frame(maxWidth: .infinity) }
                if let message = health.lastMessage { Notice(text: message, style: .success) }
                if let error = health.lastError { Notice(text: error, style: .error) }
                if !HealthReader.isAvailable { Notice(text: "Apple «Здоровье» недоступно на этом устройстве.", style: .error) }
            }
            Card {
                SectionTitle(title: "Загрузить сейчас", systemImage: "arrow.triangle.2.circlepath")
                Picker("Период", selection: $days) {
                    Text("7 дней").tag(7)
                    Text("30 дней").tag(30)
                    Text("90 дней").tag(90)
                }
                .pickerStyle(.segmented)
                Button { Task { await health.sync(days: days) } } label: {
                    Text("Синхронизировать сейчас").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                .disabled(health.isSyncing || !HealthReader.isAvailable)
                Text("Нет данных — не обязательно нет активности: часть доступа могла быть не разрешена. Доступ меняется в «Здоровье» → профиль → «Приложения» → Bolus.")
                    .font(.caption).foregroundStyle(theme.muted)
            }
            Text("Повторная синхронизация обновляет записи по UUID тренировки и по дате сводки и не создаёт копий. Удалённые в «Здоровье» записи удаляйте из дневника отдельно. Активность не меняет дозу и IOB.")
                .font(.caption).foregroundStyle(theme.muted)
        }
        .navigationTitle("Apple «Здоровье»")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var autoSync: Binding<Bool> {
        Binding(get: { store.preferences.healthAutoSync }, set: { enabled in
            Task {
                switching = true
                if enabled { await health.enable() } else { health.disable() }
                switching = false
            }
        })
    }
}
