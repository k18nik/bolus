import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(AppLockController.self) private var lock
    @Environment(\.theme) private var theme
    @State private var name = ""
    @State private var usdaKey = ""
    @State private var error: String?
    @State private var message: String?
    @State private var shared: SharedFile?
    @State private var importing = false
    @State private var planBox: PlanBox?
    @State private var confirmDeleteAll = false
    @State private var loaded = false

    static let timeZones = ["Europe/Moscow", "Europe/Kaliningrad", "Europe/Samara", "Asia/Yekaterinburg", "Asia/Novosibirsk",
                            "Asia/Irkutsk", "Asia/Vladivostok", "Europe/Berlin", "Europe/London", "America/New_York", "UTC"]

    var body: some View {
        let prefs = store.preferences
        Screen {
            PageHeading(title: "Ваше пространство", subtitle: "Настройки, которые подходят именно вам.")
            if let message { Notice(text: message, style: .success) }
            if let error { Notice(text: error, style: .error) }
            Card {
                SectionTitle(title: "О вас", systemImage: "person")
                LabeledField(title: "Имя") { TextField("Мой дневник", text: $name).onSubmit(saveName) }
                Button("Сохранить имя", action: saveName).font(.footnote)
                Picker("Единицы глюкозы", selection: preference(\.glucoseUnit)) {
                    Text("ммоль/л").tag(GlucoseUnit.mmol)
                    Text("мг/дл").tag(GlucoseUnit.mgdl)
                }
                Picker("Часовой пояс", selection: preference(\.timezoneIdentifier)) {
                    Text("Как на устройстве (\(TimeZone.current.identifier))").tag("")
                    ForEach(Self.timeZones, id: \.self) { Text($0).tag($0) }
                }
                Text("Часовой пояс определяет сегменты профиля, границы дня и отчёты.").font(.caption).foregroundStyle(theme.muted)
            }
            Card {
                SectionTitle(title: "Ваше настроение", systemImage: "paintpalette")
                Text("Тема оформления").font(.footnote.weight(.semibold)).foregroundStyle(theme.text)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(BolusTheme.all, id: \.id) { item in
                        Button { update { $0.themeID = item.id } } label: {
                            VStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 8).fill(item.swatch).frame(height: 40)
                                    .overlay(Image(systemName: "checkmark").opacity(prefs.themeID == item.id ? 1 : 0).foregroundStyle(item.accent))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.border))
                                Text(item.name).font(.caption2).foregroundStyle(prefs.themeID == item.id ? theme.accent : theme.muted)
                            }
                            .padding(8)
                            .background(prefs.themeID == item.id ? theme.mint : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Маленький помощник").font(.footnote.weight(.semibold)).foregroundStyle(theme.text)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(Mascot.all, id: \.id) { pet in
                        Button { update { $0.mascotID = pet.id } } label: {
                            VStack(spacing: 6) {
                                MascotArt(id: pet.id, size: 44)
                                Text(pet.name).font(.caption2).foregroundStyle(prefs.mascotID == pet.id ? theme.accent : theme.muted)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .background(prefs.mascotID == pet.id ? theme.mint : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Ваш помощник всегда на вашей стороне. Его настроение не зависит от показателей глюкозы.").font(.caption).foregroundStyle(theme.muted)
            }
            Card {
                SectionTitle(title: "Защита", systemImage: "faceid")
                Toggle("Блокировка: \(AppLockController.biometryName)", isOn: lockBinding)
                    .disabled(!AppLockController.isAvailable && !prefs.appLockEnabled)
                Text(AppLockController.isAvailable
                     ? "Face ID / Touch ID с запасным код-паролем устройства. Аккаунт и сервер не нужны."
                     : "На устройстве не настроен код-пароль, блокировка недоступна.")
                    .font(.caption).foregroundStyle(theme.muted)
            }
            Card {
                SectionTitle(title: "Подключения", systemImage: "link")
                NavigationLink { AISettingsView() } label: { Label("OpenAI / Tokenn", systemImage: "sparkles") }
                NavigationLink { HealthSyncView() } label: { Label("Apple «Здоровье»", systemImage: "heart") }
                Toggle("Поиск в YAZIO (нужен интернет)", isOn: preference(\.yazioEnabled))
                Toggle("Резервный каталог USDA", isOn: preference(\.usdaEnabled))
                if prefs.usdaEnabled {
                    LabeledField(title: "Ключ USDA FoodData Central", hint: KeychainStore.has(KeychainStore.usdaAccount) ? "Ключ сохранён в Keychain." : "Хранится только в Keychain.") {
                        SecureField("api.data.gov key", text: $usdaKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Button("Сохранить ключ USDA") {
                        do {
                            try KeychainStore.set(usdaKey.trimmingCharacters(in: .whitespaces), account: KeychainStore.usdaAccount)
                            usdaKey = ""
                            message = "Ключ USDA сохранён"
                        } catch { self.error = error.localizedDescription }
                    }
                    .font(.footnote)
                    .disabled(usdaKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Card {
                SectionTitle(title: "Ваши данные", systemImage: "externaldrive")
                Button(action: exportAll) { Label("Экспортировать все данные", systemImage: "square.and.arrow.up") }
                    .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                Text("JSON-копия всей локальной базы (schemaVersion \(BackupDocument.currentSchemaVersion)). API-ключи в копию не входят.")
                    .font(.caption).foregroundStyle(theme.muted)
                Button { importing = true } label: { Label("Восстановить из резервной копии", systemImage: "square.and.arrow.down") }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                Text("Поддерживаются копии этого приложения и JSON-экспорт прежнего сервера Bolus. Существующие данные не перезаписываются.")
                    .font(.caption).foregroundStyle(theme.muted)
                NavigationLink { ReportsView() } label: { Label("PDF, Excel и CSV отчёты", systemImage: "doc.text") }.font(.footnote)
                Button("Удалить все данные на устройстве", role: .destructive) { confirmDeleteAll = true }.font(.footnote)
            }
            Text("Bolus \(AppInfo.version) · \(BolusEngine.algorithmVersion) · \(IOBEngine.modelVersion)")
                .font(.caption2).foregroundStyle(theme.muted).frame(maxWidth: .infinity)
        }
        .navigationTitle("Настройки")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = store.preferences.name
        }
        .sheet(item: $shared) { file in ActivityView(items: [file.url]) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { result in readBackup(result) }
        .sheet(item: $planBox) { box in
            NavigationStack { ImportPreview(plan: box.plan, onApply: { apply(box.plan) }, onCancel: { planBox = nil }) }
                .environment(\.theme, theme)
        }
        .confirmationDialog("Удалить все данные?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Удалить всё", role: .destructive, action: deleteAll)
        } message: {
            Text("Дневник, профиль, расчёты, продукты и история AI будут удалены с этого iPhone без восстановления. Сначала можно экспортировать копию.")
        }
    }

    private func preference<Value>(_ keyPath: WritableKeyPath<AppPreferences, Value>) -> Binding<Value> {
        Binding(get: { store.preferences[keyPath: keyPath] }, set: { value in update { $0[keyPath: keyPath] = value } })
    }

    private var lockBinding: Binding<Bool> {
        Binding(get: { store.preferences.appLockEnabled }, set: { enabled in
            Task {
                if enabled {
                    guard await lock.confirmOwner() else { return }
                } else {
                    lock.disable()
                }
                update { $0.appLockEnabled = enabled }
            }
        })
    }

    private func update(_ change: (inout AppPreferences) -> Void) {
        do {
            error = nil
            try store.updatePreferences(change)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { error = "Имя: от 1 до 80 символов"; return }
        update { $0.name = trimmed }
        message = "Настройки сохранены"
    }

    private func exportAll() {
        do {
            error = nil
            let url = try ReportService.write(try store.exportBackup(), name: ReportService.backupFileName())
            shared = SharedFile(url: url)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func readBackup(_ result: Result<URL, Error>) {
        error = nil
        do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            planBox = PlanBox(plan: try store.planImport(data))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func apply(_ value: BackupImportPlan) {
        do {
            try store.applyImport(value)
            message = "Восстановлено записей: \(value.newCount). Существующие данные не изменены."
            planBox = nil
        } catch {
            self.error = error.localizedDescription
            planBox = nil
        }
    }

    private func deleteAll() {
        do {
            try store.deleteAllData()
            for provider in AIProvider.allCases { KeychainStore.delete(KeychainStore.aiKeyAccount(provider)) }
            KeychainStore.delete(KeychainStore.usdaAccount)
            ReportService.deleteAll()
            lock.disable()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PlanBox: Identifiable {
    let id = UUID()
    let plan: BackupImportPlan
}

struct ImportPreview: View {
    @Environment(\.theme) private var theme
    let plan: BackupImportPlan
    let onApply: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Screen {
            Card {
                SectionTitle(title: "Резервная копия", systemImage: "doc.badge.clock")
                DataRow(label: "Формат", value: "schemaVersion \(plan.document.schemaVersion) · \(plan.document.app.name)")
                DataRow(label: "Создана", value: plan.document.exportedAt.dateTime(.current))
                DataRow(label: "Записей в копии", value: String(plan.document.recordCount))
                Text(plan.summary).font(.footnote).foregroundStyle(theme.text)
                ForEach(plan.document.migrationNotes, id: \.self) { Text($0).font(.caption).foregroundStyle(theme.muted) }
                if !plan.conflicts.isEmpty {
                    Text("Конфликты (останется версия устройства): " + plan.conflicts.prefix(5).joined(separator: ", ") + (plan.conflicts.count > 5 ? "…" : ""))
                        .font(.caption).foregroundStyle(theme.muted)
                }
            }
            Button("Добавить \(plan.newCount) записей", action: onApply)
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                .disabled(plan.newCount == 0 && !plan.applyPreferences)
            Button("Отмена", action: onCancel).buttonStyle(SecondaryButtonStyle(fullWidth: true))
        }
        .navigationTitle("Восстановление")
        .navigationBarTitleDisplayMode(.inline)
    }
}
