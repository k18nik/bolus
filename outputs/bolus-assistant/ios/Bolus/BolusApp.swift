import SwiftUI

@main struct BolusApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene { WindowGroup { ContentView(model: model) } }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var settings = false
    @State private var health = false
    var body: some View {
        NavigationStack {
            Group {
                if model.server != nil {
                    ZStack(alignment: .top) {
                        DiaryWebView(model: model)
                        if model.loading { ProgressView().padding(12).background(.regularMaterial, in: Capsule()) }
                        if let message = model.pageError {
                            VStack(spacing: 16) {
                                Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                                Text("Не удалось открыть дневник").font(.headline)
                                Text(message).font(.subheadline).multilineTextAlignment(.center)
                                Button("Повторить") { model.reload() }.buttonStyle(.borderedProminent)
                                Button("Адрес сервера") { settings = true }
                            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
                        }
                    }
                } else { ServerForm(model: model, onSaved: {}) }
            }
            .navigationTitle("bolus.")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Настройки приложения")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { health = true } label: { Label("Здоровье", systemImage: "heart") }.disabled(model.server == nil)
                }
                ToolbarItem(placement: .bottomBar) {
                    if model.canGoBack { Button("Назад") { model.webView.goBack() } }
                }
            }
            .sheet(isPresented: $settings) { NavigationStack { ServerForm(model: model) { settings = false }.navigationTitle("Сервер дневника").toolbar { Button("Готово") { settings = false } } } }
            .sheet(isPresented: $health) { HealthSyncView(model: model) }
            .sheet(item: $model.shareFile) { file in FileShare(items: [file.url]) }
            .tint(Color(red: 0.23, green: 0.48, blue: 0.41))
        }
    }
}

struct ServerForm: View {
    @ObservedObject var model: AppModel
    var onSaved: () -> Void
    @State private var address = ""
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                Label("Ваш дневник на iPhone", systemImage: "leaf").font(.headline)
                Text("Приложение подключается к вашему Bolus-серверу. Войдите в тот же аккаунт — записи и настройки появятся здесь.")
            }
            Section("Адрес приложения") {
                TextField("https://…", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Text("На iPhone localhost означает сам телефон. Для сервера на Mac нужен его сетевой адрес или HTTPS-домен.").font(.footnote)
                if let error { Text(error).foregroundStyle(.red) }
                Button("Подключиться") {
                    guard let url = ServerAddress.parse(address) else { error = "Укажите HTTPS-адрес без пути, пароля и параметров. HTTP доступен только для локального сервера."; return }
                    model.connect(url); onSaved()
                }
            }
            Section("Apple «Здоровье»") {
                Text("Доступ к тренировкам и активности запрашивается отдельно. Перед отправкой вы увидите выбранный сервер, аккаунт и количество записей.")
                Text("Синхронизация запускается вручную. Приложение не записывает инсулин и не изменяет данные в «Здоровье».").font(.footnote)
            }
        }.onAppear { address = model.server?.absoluteString ?? "" }
    }
}

struct SharedFile: Identifiable { let id = UUID(); let url: URL }
struct FileShare: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
