import XCTest
import SwiftData
@testable import Bolus

/// End-to-end local flows on a real SwiftData store (no network, no server).
@MainActor
final class DiaryStoreTests: XCTestCase {
    private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        temporaryFiles = []
        super.tearDown()
    }

    private func storeURL() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Bolus-test.store")
        temporaryFiles.append(url)
        return url
    }

    private func makeStore(url: URL? = nil) throws -> DiaryStore {
        let container = try url.map { try PersistenceController.makeContainer(url: $0) } ?? PersistenceController.makeContainer(inMemory: true)
        let store = DiaryStore(container: container)
        try store.updatePreferences {
            $0.timezoneIdentifier = "UTC"
            $0.onboardingCompleted = true
        }
        return store
    }

    private func settings(step: Double = 1) -> TherapySettings {
        TherapySettings(rapidInsulinName: "Фиасп", basalInsulinName: "Тресиба", bolusIncrement: step, basalIncrement: 1, maxBolus: 15,
                        insulinActionDuration: 4,
                        segments: [TherapySegment(startTime: "00:00", endTime: "24:00", icr: 10, isf: 2, target: 6, correctAbove: 7)],
                        confirmed: true)
    }

    /// Acceptance flow: glucose → meal → bolus → actual dose → IOB → restart → data kept.
    func testOfflineDiaryBolusAndPersistenceAcrossRestart() throws {
        let url = try storeURL()
        var store: DiaryStore? = try makeStore(url: url)
        try XCTUnwrap(store).saveProfile(settings())
        let measured = Date().addingTimeInterval(-60)
        let batch = try XCTUnwrap(store).saveBatch(.init(occurredAt: measured, glucose: 10.2, mealName: "Обед", mealType: .lunch,
                                                         mealItems: [MealItem(nameSnapshot: "Паста", grams: 200, amount: 200, unit: .g, carbs: 62)]))
        XCTAssertEqual(batch.count, 2)
        let calculation = try XCTUnwrap(store).calculateBolus(.init(glucose: 10.2, unit: .mmol, carbs: 0, measuredAt: measured, meal: batch.meal))
        XCTAssertEqual(calculation.result?.calculationStatus, .ok)
        XCTAssertEqual(calculation.result?.unroundedBolus, 8.3)
        XCTAssertEqual(calculation.result?.recommendedBolus, 8)
        XCTAssertNil(store?.currentIOB().flatMap { $0 > 0 ? $0 : nil }, "a recommendation is not a dose")
        let entry = try XCTUnwrap(try XCTUnwrap(store).confirmBolus(calculationID: calculation.id, units: 8, administeredAt: Date()))
        XCTAssertEqual(entry.insulin?.dia, 4)
        XCTAssertEqual(try XCTUnwrap(store?.currentIOB()), 8, accuracy: 0.01)
        _ = try XCTUnwrap(store).confirmBolus(calculationID: calculation.id, units: 8, administeredAt: Date())
        XCTAssertEqual(store?.allEntries().filter { $0.kind == .insulin }.count, 1, "confirmation is idempotent")
        store = nil

        let reopened = DiaryStore(container: try PersistenceController.makeContainer(url: url))
        XCTAssertTrue(reopened.preferences.onboardingCompleted)
        XCTAssertEqual(reopened.allEntries().count, 3)
        XCTAssertEqual(reopened.latestGlucose()?.data.double("value_mmol"), 10.2)
        XCTAssertEqual(reopened.calculation(id: calculation.id)?.actualBolus, 8)
        XCTAssertEqual(reopened.calculation(id: calculation.id)?.result?.recommendedBolus, 8)
        XCTAssertEqual(try XCTUnwrap(reopened.currentIOB()), 8, accuracy: 0.05)
    }

    func testBlockedCalculationIsStoredButCannotBeConfirmed() throws {
        let store = try makeStore()
        try store.saveProfile(settings())
        let stale = try store.calculateBolus(.init(glucose: 9, unit: .mmol, carbs: 20, measuredAt: Date().addingTimeInterval(-3600)))
        XCTAssertEqual(stale.result?.calculationStatus, .blocked)
        XCTAssertEqual(stale.result?.warnings, ["stale_glucose"])
        XCTAssertNotNil(store.calculation(id: stale.id))
        XCTAssertThrowsError(try store.confirmBolus(calculationID: stale.id, units: 1, administeredAt: Date()))
        XCTAssertTrue(store.allEntries().isEmpty)
    }

    func testProfileVersionsAreNeverRewritten() throws {
        let store = try makeStore()
        let first = try store.saveProfile(settings(step: 0.5))
        var changed = settings()
        changed.segments[0].icr = 12
        let second = try store.saveProfile(changed)
        let profiles = store.profiles()
        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(store.activeProfile()?.id, second.id)
        let archived = try XCTUnwrap(profiles.first { $0.id == first.id })
        XCTAssertEqual(archived.status, "archived")
        XCTAssertEqual(archived.settings.segments[0].icr, 10)
        XCTAssertEqual(archived.settings.bolusIncrement, 0.5)
    }

    func testHealthSyncDoesNotDuplicate() throws {
        let store = try makeStore()
        let now = Date()
        let workout = HealthWorkout(id: UUID().uuidString, name: "Бег", sourceName: "Apple Watch", startedAt: now.addingTimeInterval(-3600),
                                    endedAt: now.addingTimeInterval(-1800), durationMinutes: 30, activeEnergy: 250, distanceKm: 4.2)
        let day = HealthDay(date: LocalDate.today(in: store.timeZone).description, steps: 5000)
        let payload = HealthPayload(timezone: "UTC", workouts: [workout], days: [day])
        XCTAssertEqual(try store.applyHealth(payload).inserted, 2)
        let again = try store.applyHealth(payload)
        XCTAssertEqual(again.inserted, 0)
        XCTAssertEqual(again.unchanged, 2)
        XCTAssertEqual(store.allEntries().count, 2)
    }

    func testBackupRoundTripAndNonDestructiveImport() throws {
        let source = try makeStore()
        try source.saveProfile(settings())
        try source.saveBatch(.init(occurredAt: Date().addingTimeInterval(-120), glucose: 6.4, note: "Заметка"))
        try source.saveFood(try FoodNutrition.customFood(name: "Сырник", carbs: 23))
        try source.saveCycle(start: LocalDate.today(in: source.timeZone).adding(days: -3), length: 28)
        let data = try source.exportBackup()

        let target = try makeStore()
        let plan = try target.planImport(data)
        XCTAssertEqual(plan.document.schemaVersion, BackupDocument.currentSchemaVersion)
        XCTAssertGreaterThan(plan.newCount, 0)
        try target.applyImport(plan)
        XCTAssertEqual(target.allEntries().count, source.allEntries().count)
        XCTAssertEqual(target.profiles().count, 1)
        XCTAssertEqual(target.foods().count, 1)
        XCTAssertEqual(target.cycles().count, 1)

        let again = try target.planImport(data)
        XCTAssertEqual(again.newCount, 0, "re-import must not duplicate")
        XCTAssertTrue(again.conflicts.isEmpty)
    }

    func testDeleteEntryAndAllData() throws {
        let store = try makeStore()
        let result = try store.saveBatch(.init(occurredAt: Date(), glucose: 7.1))
        try store.deleteEntry(id: try XCTUnwrap(result.glucose).id)
        XCTAssertTrue(store.allEntries().isEmpty)
        try store.saveBatch(.init(occurredAt: Date(), note: "x"))
        try store.deleteAllData()
        XCTAssertTrue(store.allEntries().isEmpty)
        XCTAssertFalse(store.preferences.onboardingCompleted)
    }

    func testReportsAreGeneratedLocally() throws {
        let store = try makeStore()
        try store.saveProfile(settings())
        try store.saveBatch(.init(occurredAt: Date().addingTimeInterval(-300), glucose: 8.2, manualCarbs: 30))
        let today = store.today
        for format in ReportFormat.allCases {
            let (from, to) = ReportOptions.period(days: 7, endingAt: today)
            let url = try ReportService.generate(ReportOptions(type: .doctor, format: format, from: from, to: to), store: store)
            let data = try Data(contentsOf: url)
            XCTAssertGreaterThan(data.count, 100, format.rawValue)
            if format == .pdf { XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "%PDF") }
            if format == .xlsx || format == .csv { XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B]) }
            ReportService.delete(url)
        }
    }
}
