import Foundation
import HealthKit

final class HealthReader {
    private let store = HKHealthStore()
    private let types: [HKQuantityTypeIdentifier] = [.stepCount, .activeEnergyBurned, .appleExerciseTime, .distanceWalkingRunning]
    func read(days: Int, userID: String) async throws -> HealthPayload {
        guard HKHealthStore.isHealthDataAvailable() else { throw AppFailure(message: "Apple «Здоровье» недоступно на этом устройстве.") }
        let quantities = types.compactMap { HKObjectType.quantityType(forIdentifier: $0) }
        let readTypes: Set<HKObjectType> = Set(quantities + [HKObjectType.workoutType()])
        try await store.requestAuthorization(toShare: [], read: readTypes)
        // Successful authorization means the prompt completed, not that all read types were granted.
        let calendar = Calendar.current
        let end = Date()
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: end))!
        let workouts = try await readWorkouts(start: start, end: end)
        var rows: [String: HealthDay] = [:]
        for identifier in types {
            let values = try await readTotals(identifier, start: start, end: end)
            for (day, value) in values {
                var row = rows[day] ?? HealthDay(date: day)
                switch identifier {
                case .stepCount: row.steps = Int(value.rounded())
                case .activeEnergyBurned: row.active_energy = value
                case .appleExerciseTime: row.exercise_minutes = value
                case .distanceWalkingRunning: row.distance_km = value
                default: break
                }
                rows[day] = row
            }
        }
        return HealthPayload(userID: userID, timezone: TimeZone.current.identifier, workouts: workouts, days: rows.values.filter(\.hasData).sorted { $0.date < $1.date })
    }
    private func readWorkouts(start: Date, end: Date) async throws -> [HealthWorkout] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate, .strictEndDate])
            let query = HKSampleQuery(sampleType: .workoutType(), predicate: predicate, limit: 1001, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                let workouts = samples as? [HKWorkout] ?? []
                guard workouts.count <= 1000 else { continuation.resume(throwing: AppFailure(message: "Слишком много тренировок. Выберите меньший период.")); return }
                let results = workouts.filter { $0.duration > 0 && $0.duration <= 86400 }.map { workout in
                    HealthWorkout(id: workout.uuid.uuidString.lowercased(), name: Self.workoutName(workout.workoutActivityType), source: workout.sourceRevision.source.name, start: workout.startDate, end: workout.endDate, minutes: workout.duration / 60, energy: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()), distance: workout.totalDistance?.doubleValue(for: .meterUnit(with: .kilo)))
                }
                continuation.resume(returning: results)
            }
            store.execute(query)
        }
    }
    private func readTotals(_ identifier: HKQuantityTypeIdentifier, start: Date, end: Date) async throws -> [String: Double] {
        try await withCheckedThrowingContinuation { continuation in
            let type = HKQuantityType(identifier)
            let query = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end), options: .cumulativeSum, anchorDate: start, intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, error in
                if let error { continuation.resume(throwing: error); return }
                var result: [String: Double] = [:]
                let format = DateFormatter(); format.calendar = Calendar(identifier: .gregorian); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = .current; format.dateFormat = "yyyy-MM-dd"
                let unit: HKUnit = identifier == .stepCount ? .count() : identifier == .activeEnergyBurned ? .kilocalorie() : identifier == .appleExerciseTime ? .minute() : .meterUnit(with: .kilo)
                collection?.enumerateStatistics(from: start, to: end) { item, _ in
                    if let value = item.sumQuantity()?.doubleValue(for: unit), value.isFinite { result[format.string(from: item.startDate)] = value }
                }
                continuation.resume(returning: result)
            }
            store.execute(query)
        }
    }
    private static func workoutName(_ type: HKWorkoutActivityType) -> String {
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
