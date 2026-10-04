import SwiftUI
import SwiftData

@main
struct BolusApp: App {
    @State private var store: DiaryStore
    @State private var lock = AppLockController()
    @State private var network = NetworkMonitor()
    @State private var health: HealthSyncController
    @State private var startupError: String?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let diary: DiaryStore
        var failure: String?
        do {
            diary = DiaryStore(container: try PersistenceController.makeContainer())
        } catch {
            // The app stays usable (in-memory) and explains the problem instead of crashing.
            diary = DiaryStore(container: try! PersistenceController.makeContainer(inMemory: true))
            failure = "Не удалось открыть локальную базу: \(error.localizedDescription). Данные этого сеанса не сохранятся."
        }
        // Observer queries are registered at every launch, also when HealthKit wakes the app in the background.
        let healthSync = HealthSyncController(store: diary)
        healthSync.start()
        _store = State(initialValue: diary)
        _health = State(initialValue: healthSync)
        _startupError = State(initialValue: failure)
    }

    var body: some Scene {
        WindowGroup {
            RootView(startupError: startupError)
                .environment(store)
                .environment(lock)
                .environment(network)
                .environment(health)
                .modelContainer(store.container)
                .onAppear { lock.lock(if: store.preferences.appLockEnabled) }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .background { lock.lock(if: store.preferences.appLockEnabled) }
            if phase == .active { health.appBecameActive() }
        }
    }
}
