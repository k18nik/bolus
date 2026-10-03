import Foundation
import SwiftUI
import WebKit

struct AppFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct DiaryAccount: Decodable { let id: String; let name: String }
struct SyncResult: Decodable { let inserted: Int; let updated: Int; let unchanged: Int }

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class AppModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    @Published var server: URL?
    @Published var loading = false
    @Published var pageError: String?
    @Published var canGoBack = false
    @Published var shareFile: SharedFile?
    let webView: WKWebView
    private var pendingDownload: URL?

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        server = UserDefaults.standard.string(forKey: "bolusServer").flatMap(ServerAddress.parse)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false; webView.backgroundColor = .systemBackground
        if let server { webView.load(URLRequest(url: server)) }
    }
    func connect(_ url: URL) {
        server = url; pageError = nil
        UserDefaults.standard.set(url.absoluteString, forKey: "bolusServer")
        webView.load(URLRequest(url: url))
    }
    func reload() { pageError = nil; if let server { webView.load(URLRequest(url: server)) } }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true; pageError = nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false; canGoBack = webView.canGoBack }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        loading = false; pageError = "Проверьте соединение и доступность выбранного сервера."
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let server, ServerAddress.sameOrigin(url, server) else { decisionHandler(.cancel); return }
        if action.shouldPerformDownload { decisionHandler(.download) } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let attachment = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") ?? false
        decisionHandler(attachment || !response.canShowMIMEType ? .download : .allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, let server, ServerAddress.sameOrigin(url, server) { webView.load(action.request) }
        return nil
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
            let file = folder.appendingPathComponent((suggestedFilename as NSString).lastPathComponent)
            pendingDownload = file; completionHandler(file)
        } catch { completionHandler(nil) }
    }
    func downloadDidFinish(_ download: WKDownload) { if let pendingDownload { shareFile = SharedFile(url: pendingDownload) }; pendingDownload = nil }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { pendingDownload = nil; pageError = "Не удалось скачать отчёт. Повторите загрузку." }

    func request(_ path: String, body: Data? = nil, expectedServer: URL) async throws -> Data {
        guard let server, ServerAddress.sameOrigin(server, expectedServer) else { throw AppFailure(message: "Сервер изменился. Откройте синхронизацию заново.") }
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let scoped = cookies.filter { cookie in
            cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == server.host?.lowercased() && ["session", "csrf"].contains(cookie.name) && (!cookie.isSecure || server.scheme == "https")
        }
        guard scoped.contains(where: { $0.name == "session" }), let csrf = scoped.first(where: { $0.name == "csrf" }) else { throw AppFailure(message: "Сначала войдите в аккаунт дневника.") }
        var request = URLRequest(url: server.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpShouldHandleCookies = false
        request.allHTTPHeaderFields = HTTPCookie.requestHeaderFields(with: scoped)
        request.setValue(csrf.value, forHTTPHeaderField: "X-CSRF-Token")
        request.setValue(server.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body; request.timeoutInterval = 60
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppFailure(message: "Некорректный ответ сервера.") }
        if http.statusCode == 401 || http.statusCode == 403 { throw AppFailure(message: "Сессия завершена. Снова войдите в дневник.") }
        if http.statusCode == 409 { throw AppFailure(message: "Аккаунт изменился. Заново подготовьте синхронизацию.") }
        guard (200...299).contains(http.statusCode) else { throw AppFailure(message: "Сервер не принял данные (\(http.statusCode)). Обновите сервер и повторите попытку.") }
        return data
    }
    func account(at server: URL) async throws -> DiaryAccount { try JSONDecoder().decode(DiaryAccount.self, from: await request("api/users/me", expectedServer: server)) }
    func sync(_ payload: HealthPayload, at server: URL) async throws -> SyncResult {
        let data = try JSONEncoder().encode(payload)
        return try JSONDecoder().decode(SyncResult.self, from: await request("api/imports/healthkit", body: data, expectedServer: server))
    }
}

struct DiaryWebView: UIViewRepresentable {
    @ObservedObject var model: AppModel
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
