import SwiftUI

/// Optional AI explanations. Nothing else in the app depends on it: diary, bolus, IOB,
/// HealthKit, analytics and reports work without AI and without network.
struct AIView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.theme) private var theme
    var calculationID: UUID? = nil
    @State private var question = ""
    @State private var days = 14
    @State private var includeCalculation = true
    @State private var busy = false
    @State private var error: String?
    @State private var showSettings = false

    var body: some View {
        let _ = store.revision
        let prefs = store.preferences
        let provider = AIProvider(rawValue: prefs.aiProvider) ?? .openai
        let hasKey = KeychainStore.has(KeychainStore.aiKeyAccount(provider))
        let ready = hasKey && prefs.aiConsent
        Screen {
            PageHeading(title: "Ваш AI-ассистент", subtitle: "Понятные объяснения ваших наблюдений.")
            Card {
                HStack {
                    Label("Анализ дневника", systemImage: "sparkles").font(.headline).foregroundStyle(theme.text)
                    Spacer()
                    Button("Подключение") { showSettings = true }.font(.footnote)
                }
                Text("AI получает только агрегаты периода и, по вашему выбору, снимок выполненного расчёта. Имя, заметки и вся база не отправляются. AI не меняет профиль и не выдаёт дозы.")
                    .font(.caption).foregroundStyle(theme.muted)
                if !network.isOnline {
                    Notice(text: "Нет подключения к интернету. AI недоступен, а дневник, расчёт болюса, IOB, аналитика и отчёты продолжают работать.",
                           systemImage: "wifi.slash")
                }
                if !ready {
                    Notice(text: hasKey ? "Разрешите передачу агрегатов сервису \(provider.name) в настройках подключения."
                                        : "Добавьте свой API-ключ \(provider.name). Ключ хранится только в Keychain этого iPhone.")
                }
                ForEach(AIAssistant.suggestedQuestions, id: \.self) { suggestion in
                    Button(suggestion) { question = suggestion }
                        .font(.footnote)
                        .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                }
                if let calculationID {
                    Toggle("Передать выбранный расчёт болюса", isOn: $includeCalculation)
                    if store.calculation(id: calculationID) == nil { Text("Расчёт не найден").font(.caption).foregroundStyle(theme.muted) }
                }
                Picker("Период", selection: $days) {
                    Text("7 дней").tag(7)
                    Text("14 дней").tag(14)
                    Text("30 дней").tag(30)
                    Text("90 дней").tag(90)
                }
                .pickerStyle(.segmented)
                TextField("Ваш вопрос", text: $question, axis: .vertical)
                    .lineLimit(2...6)
                    .padding(10)
                    .background(theme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                if let error { Notice(text: error, style: .error) }
                Button {
                    Task { await ask(provider: provider) }
                } label: {
                    if busy { ProgressView() } else { Label("Отправить в \(provider.name)", systemImage: "paperplane") }
                }
                .buttonStyle(PrimaryButtonStyle(fullWidth: true))
                .disabled(busy || !ready || !network.isOnline || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            let history = store.insights()
            if !history.isEmpty {
                SectionTitle(title: "История анализов")
                ForEach(history) { InsightCard(insight: $0) }
                Text("Анализов: \(history.count) · использовано токенов: \(store.totalTokens())").font(.caption).foregroundStyle(theme.muted)
            }
        }
        .navigationTitle("AI")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSettings) { NavigationStack { AISettingsView() }.environment(\.theme, theme) }
        .onAppear {
            if calculationID != nil && question.isEmpty {
                question = "Объясни компоненты этого расчёта болюса и какие данные стоит проверить."
            }
        }
    }

    private func ask(provider: AIProvider) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            guard let key = KeychainStore.get(KeychainStore.aiKeyAccount(provider)) else { throw AIError.message("Добавьте API-ключ в настройках AI.") }
            let selected = includeCalculation ? calculationID : nil
            let context = store.aiContext(days: days, calculationID: selected)
            let model = store.preferences.aiModel
            let result = try await AIAssistant.generateInsight(provider: provider, key: key, model: model, question: question,
                                                               context: context, transport: HTTPClient.transport)
            let record = AIInsightRecord(question: question, response: try JSONValue.encode(result.insight), context: context,
                                         provider: provider.rawValue, model: model, usage: result.usage, calculationID: selected)
            try store.saveInsight(record)
            question = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct InsightCard: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.theme) private var theme
    let insight: AIInsightRecord

    var body: some View {
        let response = try? insight.response.decode(AIInsightResponse.self)
        Card {
            Text(insight.question).font(.subheadline.weight(.semibold)).foregroundStyle(theme.text)
            Text("\(insight.createdAt.dateTime(store.timeZone)) · \(AIProvider(rawValue: insight.provider)?.name ?? insight.provider) · \(insight.model) · \(insight.totalTokens) токенов")
                .font(.caption2).foregroundStyle(theme.muted)
            if let response {
                Text(response.summary).font(.footnote).foregroundStyle(theme.text)
                list("Наблюдения", response.observations)
                list("Возможные объяснения", response.possibleExplanations)
                list("Вопросы для обсуждения", response.questions)
                list("Важно", response.safetyFlags)
            }
        }
    }

    @ViewBuilder private func list(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(theme.accent)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in Text("• " + item).font(.footnote).foregroundStyle(theme.text) }
        }
    }
}

struct AISettingsView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var provider: AIProvider = .openai
    @State private var key = ""
    @State private var model = ""
    @State private var consent = false
    @State private var message: String?
    @State private var error: String?
    @State private var busy = false
    @State private var loaded = false

    var body: some View {
        let hasKey = KeychainStore.has(KeychainStore.aiKeyAccount(provider))
        Screen {
            Notice(text: "Ключ хранится только в Keychain этого iPhone: не в настройках, не в базе и не в резервной копии.", systemImage: "key")
            Card {
                Picker("Провайдер", selection: $provider) {
                    ForEach(AIProvider.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Адрес API: \(provider.baseURL.absoluteString)").font(.caption).foregroundStyle(theme.muted)
                LabeledField(title: "API-ключ \(provider.name)", hint: hasKey ? "Ключ сохранён. Оставьте поле пустым, чтобы его не менять." : "Ключ из вашего аккаунта \(provider.name).") {
                    SecureField(hasKey ? "Ключ сохранён" : "sk-…", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                LabeledField(title: "Модель", hint: "Модель Responses API со Structured Outputs, доступная вашему ключу.") {
                    TextField(provider.defaultModel, text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Toggle(isOn: $consent) {
                    Text("Разрешаю отправлять \(provider.name) мой вопрос, агрегаты глюкозы, питания, инсулина, активности и цикла, а при разборе болюса — снимок выбранного расчёта.")
                        .font(.footnote)
                }
            }
            if let message { Notice(text: message, style: .success) }
            if let error { Notice(text: error, style: .error) }
            Button("Сохранить подключение", action: save).buttonStyle(PrimaryButtonStyle(fullWidth: true))
            if hasKey {
                Button {
                    Task { await test() }
                } label: {
                    if busy { ProgressView() } else { Text("Проверить подключение") }
                }
                .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                .disabled(busy || !network.isOnline)
                Text("Проверка — короткий запрос без данных дневника; он расходует токены.").font(.caption).foregroundStyle(theme.muted)
                Button("Удалить ключ", role: .destructive) {
                    KeychainStore.delete(KeychainStore.aiKeyAccount(provider))
                    try? store.updatePreferences { $0.aiConsent = false }
                    consent = false
                    message = "Ключ удалён с устройства"
                }
                .font(.footnote)
            }
        }
        .navigationTitle("Подключение AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            provider = AIProvider(rawValue: store.preferences.aiProvider) ?? .openai
            model = store.preferences.aiModel
            consent = store.preferences.aiConsent
        }
        .onChange(of: provider) { _, newValue in
            // A saved key is never sent to another provider; consent is per provider.
            if loaded && newValue.rawValue != store.preferences.aiProvider {
                consent = false
                key = ""
                if model == AIProvider.openai.defaultModel || model == AIProvider.tokenn.defaultModel { model = newValue.defaultModel }
            }
        }
    }

    private func save() {
        error = nil
        message = nil
        do {
            let validModel = try AIAssistant.validateModel(model.isEmpty ? provider.defaultModel : model)
            if !key.isEmpty {
                try KeychainStore.set(try AIAssistant.validateKey(key), account: KeychainStore.aiKeyAccount(provider))
                key = ""
            }
            try store.updatePreferences {
                $0.aiProvider = provider.rawValue
                $0.aiModel = validModel
                $0.aiConsent = consent
            }
            message = "Настройки AI сохранены"
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func test() async {
        busy = true
        error = nil
        message = nil
        defer { busy = false }
        do {
            guard let saved = KeychainStore.get(KeychainStore.aiKeyAccount(provider)) else { throw AIError.message("Сначала сохраните ключ.") }
            let usage = try await AIAssistant.testConnection(provider: provider, key: saved, model: store.preferences.aiModel, transport: HTTPClient.transport)
            message = "\(provider.name): ключ и модель работают. Тест использовал \(AIInsightRecord.tokenCount(usage)) токенов."
        } catch {
            self.error = error.localizedDescription
        }
    }
}
