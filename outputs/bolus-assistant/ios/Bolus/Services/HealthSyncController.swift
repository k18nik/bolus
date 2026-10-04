import Foundation
import HealthKit
import Observation

/// Direct, automatic link Apple Health → local diary. When it is on, new workouts and daily
/// activity are saved on launch, on every return to the app and when HealthKit reports new
/// data (also in the background). Reading and saving stay on the iPhone; repeated syncs
/// update records by workout UUID and day instead of adding copies.
@MainActor
@Observable
final class HealthSyncController {
    private(set) var isSyncing = false
    private(set) var lastMessage: String?
    private(set) var lastError: String?
    private let store: DiaryStore
    private let reader = HealthReader()
    private var observing = false

    /// Days read on the first automatic sync.
    static let initialDays = 30

    init(store: DiaryStore) {
        self.store = store
    }

    var isEnabled: Bool { store.preferences.healthAutoSync }

    /// At launch (also when HealthKit launches the app in the background).
    func start() {
        guard isEnabled else { return }
        startObserving()
    }

    /// Every return to the app catches up on what Health collected meanwhile.
    func appBecameActive() {
        guard isEnabled else { return }
        startObserving()
        if let last = store.preferences.healthLastSync, Date().timeIntervalSince(last) < 10 * 60 { return }
        Task { await sync() }
    }

    func enable() async {
        lastError = nil
        do {
            try await reader.requestAccess()
            try store.updatePreferences { $0.healthAutoSync = true }
            startObserving()
            await sync(days: Self.initialDays)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func disable() {
        reader.stopBackgroundDelivery()
        try? store.updatePreferences { $0.healthAutoSync = false }
        lastMessage = "Автоматическая синхронизация выключена. Сохранённые записи остаются в дневнике."
    }

    /// Reads the period since the last sync (at least two days, so late samples are caught).
    @discardableResult
    func sync(days requested: Int? = nil) async -> Bool {
        guard !isSyncing else { return false }
        isSyncing = true
        defer { isSyncing = false }
        let days = requested ?? daysSinceLastSync()
        do {
            let payload = try await reader.read(days: days, timeZone: store.timeZone)
            if payload.workouts.isEmpty && payload.days.isEmpty {
                lastMessage = "Новых данных в «Здоровье» нет."
            } else {
                let plan = try store.applyHealth(payload)
                lastMessage = "Добавлено: \(plan.inserted). Обновлено: \(plan.updated). Без изменений: \(plan.unchanged)."
            }
            try store.updatePreferences { $0.healthLastSync = Date() }
            lastError = nil
            return true
        } catch let error as HKError where error.code == .errorDatabaseInaccessible {
            // iPhone is locked: Health data is encrypted until unlock, the next sync catches up.
            return false
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func daysSinceLastSync() -> Int {
        guard let last = store.preferences.healthLastSync else { return Self.initialDays }
        let days = Int((Date().timeIntervalSince(last) / 86400).rounded(.up)) + 1
        return min(max(days, 2), 90)
    }

    private func startObserving() {
        guard !observing, HealthReader.isAvailable else { return }
        observing = true
        reader.observeChanges { [weak self] completion in
            Task { @MainActor in
                if let self, self.isEnabled {
                    if let last = self.store.preferences.healthLastSync, Date().timeIntervalSince(last) < 60 {
                        completion()
                        return
                    }
                    await self.sync()
                }
                completion()
            }
        }
    }
}
