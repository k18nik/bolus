import SwiftUI
import SwiftData

@main
struct BolusApp: App {
    @State private var store: DiaryStore
    @State private var lock = AppLockController()
    @State private var network = NetworkMonitor()
    @State private var startupError: String?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        do {
            _store = State(initialValue: DiaryStore(container: try PersistenceController.makeContainer()))
        } catch {
            // The app stays usable (in-memory) and explains the problem instead of crashing.
            let fallback = try! PersistenceController.makeContainer(inMemory: true)
            _store = State(initialValue: DiaryStore(container: fallback))
            _startupError = State(initialValue: "Не удалось открыть локальную базу: \(error.localizedDescription). Данные этого сеанса не сохранятся.")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(startupError: startupError)
                .environment(store)
                .environment(lock)
                .environment(network)
                .modelContainer(store.container)
                .onAppear { lock.lock(if: store.preferences.appLockEnabled) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { lock.lock(if: store.preferences.appLockEnabled) }
        }
    }
}
