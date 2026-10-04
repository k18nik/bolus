import Foundation
import HealthKit

/// Reads workouts and daily activity from HealthKit (read-only, on device).
/// HealthKit → SwiftData: the result is saved by `DiaryStore.applyHealth`, no server.
final class HealthReader {
    private let store = HKHealthStore()
    private let types: [HKQuantityTypeIdentifier] = [.stepCount, .activeEnergyBurned, .appleExerciseTime, .distanceWalkingRunning]

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var sampleTypes: [HKSampleType] {
        types.compactMap { HKObjectType.quantityType(forIdentifier: $0) } + [HKObjectType.workoutType()]
    }

    /// Asks for read access once; later calls return without showing anything.
    func requestAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw BolusError.validation("Apple «Здоровье» недоступно на этом устройстве.") }
        try await store.requestAuthorization(toShare: [], read: Set(sampleTypes.map { $0 as HKObjectType }))
    }

    /// Direct link: observer queries fire when Health gets new workouts or activity, and
    /// background delivery wakes the app for them (entitlement `healthkit.background-delivery`).
    /// `onChange` must call the completion handler when the new data is saved.
    func observeChanges(_ onChange: @escaping (@escaping () -> Void) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        for type in sampleTypes {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                guard error == nil else { completion(); return }
                onChange(completion)
            }
            store.execute(query)
            let frequency: HKUpdateFrequency = type == HKObjectType.workoutType() ? .immediate : .hourly
            store.enableBackgroundDelivery(for: type, frequency: frequency) { _, _ in }
        }
    }

    func stopBackgroundDelivery() {
        store.disableAllBackgroundDelivery { _, _ in }
    }

    func read(days: Int, timeZone: TimeZone) async throws -> HealthPayload {
        try await requestAccess()
        // Successful authorization means the prompt completed, not that all read types were granted.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let end = Date()
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: end)) else {
            throw BolusError.validation("Некорректный период")
        }
        let workouts = try await readWorkouts(start: start, end: end)
        var rows: [String: HealthDay] = [:]
        for identifier in types {
            let values = try await readTotals(identifier, start: start, end: end, timeZone: timeZone)
            for (day, value) in values {
                var row = rows[day] ?? HealthDay(date: day)
                switch identifier {
                case .stepCount: row.steps = Int(value.rounded())
                case .activeEnergyBurned: row.activeEnergy = value
                case .appleExerciseTime: row.exerciseMinutes = value
                case .distanceWalkingRunning: row.distanceKm = value
                default: break
                }
                rows[day] = row
            }
        }
        return HealthPayload(timezone: timeZone.identifier, workouts: workouts,
                             days: rows.values.filter(\.hasData).sorted { $0.date < $1.date })
    }

    private func readWorkouts(start: Date, end: Date) async throws -> [HealthWorkout] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate, .strictEndDate])
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: 1001,
                                      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let workouts = samples as? [HKWorkout] ?? []
                guard workouts.count <= 1000 else {
                    continuation.resume(throwing: BolusError.validation("Слишком много тренировок. Выберите меньший период."))
                    return
                }
                let results = workouts.filter { $0.duration > 0 && $0.duration <= 86400 }.map { workout in
                    HealthWorkout(id: workout.uuid.uuidString, name: Self.workoutName(workout.workoutActivityType),
                                  sourceName: workout.sourceRevision.source.name, startedAt: workout.startDate, endedAt: workout.endDate,
                                  durationMinutes: workout.duration / 60,
                                  activeEnergy: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()),
                                  distanceKm: workout.totalDistance?.doubleValue(for: .meterUnit(with: .kilo)))
                }
                continuation.resume(returning: results)
            }
            store.execute(query)
        }
    }

    private func readTotals(_ identifier: HKQuantityTypeIdentifier, start: Date, end: Date, timeZone: TimeZone) async throws -> [String: Double] {
        try await withCheckedThrowingContinuation { continuation in
            let type = HKQuantityType(identifier)
            let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end),
                                                    options: .cumulativeSum, anchorDate: start, intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, error in
                if let error { continuation.resume(throwing: error); return }
                var result: [String: Double] = [:]
                let unit: HKUnit = identifier == .stepCount ? .count() : identifier == .activeEnergyBurned ? .kilocalorie()
                    : identifier == .appleExerciseTime ? .minute() : .meterUnit(with: .kilo)
                collection?.enumerateStatistics(from: start, to: end) { item, _ in
                    // Missing values stay missing: no data is never turned into zero activity.
                    if let value = item.sumQuantity()?.doubleValue(for: unit), value.isFinite {
                        result[LocalDate(date: item.startDate, timeZone: timeZone).description] = value
                    }
                }
                continuation.resume(returning: result)
            }
            store.execute(query)
        }
    }

    static func workoutName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .walking: return "Ходьба"
        case .running: return "Бег"
        case .cycling: return "Велосипед"
        case .swimming: return "Плавание"
        case .yoga: return "Йога"
        case .traditionalStrengthTraining: return "Силовая тренировка"
        case .functionalStrengthTraining: return "Функциональная тренировка"
        case .hiking: return "Поход"
        case .pilates: return "Пилатес"
        case .dance, .cardioDance, .socialDance: return "Танцы"
        case .highIntensityIntervalTraining: return "Интервальная тренировка"
        case .elliptical: return "Эллиптический тренажёр"
        default: return "Тренировка"
        }
    }
}
