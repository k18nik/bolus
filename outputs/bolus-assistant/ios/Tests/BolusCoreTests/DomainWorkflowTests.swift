import XCTest
@testable import BolusCore

/// Ports of the endpoint-level tests (`test_api.py`, `test_personal_mode.py`,
/// `test_healthkit.py`, `test_yazio.py`) to the local workflows.
final class DomainWorkflowTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    let moscow = TimeZone(identifier: "Europe/Moscow")!
    let now = referenceInstant

    func personalProfile(step: Double = 1, validFrom: Date? = nil) throws -> TherapyProfileRecord {
        let settings = TherapySettings(rapidInsulinName: "Фиасп", basalInsulinName: "Тресиба", bolusIncrement: step, basalIncrement: 1,
                                       maxBolus: 15, insulinActionDuration: 4,
                                       segments: [TherapySegment(startTime: "00:00", endTime: "24:00", icr: 10, isf: 2, target: 6, correctAbove: 7)],
                                       confirmed: true)
        var profile = try ProfileWorkflow.newVersion(settings, existing: [], now: validFrom ?? now.addingTimeInterval(-86400)).profile
        profile.validFrom = validFrom ?? now.addingTimeInterval(-86400)
        return profile
    }

    // MARK: Entries

    func testGlucoseUnitsAndPlausibility() throws {
        let factory = EntryFactory(now: now, timeZone: utc)
        let entry = try factory.glucose(value: 180, unit: .mgdl, measuredAt: now)
        XCTAssertEqual(entry.data.double("value_mmol"), 10)
        XCTAssertEqual(entry.glucose?.unit, .mgdl)
        XCTAssertThrowsError(try factory.glucose(value: 180, unit: .mmol, measuredAt: now))
        XCTAssertThrowsError(try factory.glucose(value: 6, unit: .mmol, measuredAt: now.addingTimeInterval(301)))
        XCTAssertNoThrow(try factory.glucose(value: 6, unit: .mmol, measuredAt: now.addingTimeInterval(299)))
    }

    func testInsulinRulesFiaspTresibaAndStep() throws {
        let factory = EntryFactory(now: now, timeZone: utc)
        XCTAssertThrowsError(try factory.insulin(units: 2, type: .rapid, administeredAt: now, profiles: []), "rapid needs DIA from profile")
        XCTAssertNoThrow(try factory.insulin(units: 10, type: .basal, purpose: .basal, administeredAt: now, profiles: []))
        let profile = try personalProfile()
        XCTAssertThrowsError(try factory.insulin(units: 2, type: .basal, purpose: .meal, administeredAt: now, profiles: [profile]))
        XCTAssertThrowsError(try factory.insulin(units: 10, type: .rapid, name: "Тресиба", purpose: .meal, administeredAt: now, profiles: [profile]))
        XCTAssertThrowsError(try factory.insulin(units: 1.5, type: .rapid, administeredAt: now, profiles: [profile])) { error in
            XCTAssertEqual(error.localizedDescription, "Доза должна быть кратна шагу устройства 1 ЕД")
        }
        let basal = try factory.insulin(units: 10, type: .basal, purpose: .basal, administeredAt: now, profiles: [profile])
        XCTAssertEqual(basal.insulin?.insulinName, "Тресиба")
        XCTAssertEqual(basal.insulin?.insulinID, "tresiba")
        XCTAssertNil(basal.insulin?.dia)
        let rapid = try factory.insulin(units: 3, type: .rapid, administeredAt: now, profiles: [profile])
        XCTAssertEqual(rapid.insulin?.insulinID, "fiasp")
        XCTAssertEqual(rapid.insulin?.dia, 4)
        XCTAssertEqual(rapid.insulin?.doseIncrement, 1)
        XCTAssertEqual(rapid.insulin?.actionModel, "linear-remaining-v1.0.0")
    }

    func testMealSnapshotTotalsAndQuantityBasis() throws {
        let factory = EntryFactory(now: now, timeZone: utc)
        let cola = FoodRecord(name: "Кола", source: "yazio", externalID: "catalog-1", baseUnit: "ml", servingName: "100 мл",
                              servingWeight: 100, carbs: 10.58, protein: 0, fat: 0, calories: 41)
        let item = FoodNutrition.item(from: cola, amount: 250)
        XCTAssertNil(item.grams)
        XCTAssertNil(item.fiber)
        let meal = try factory.meal(name: "Напиток", eatenAt: now, items: [item])
        XCTAssertEqual(meal.data.double("total_carbs"), 26.45)
        var invalid = item
        invalid.unit = .g
        XCTAssertThrowsError(try factory.meal(eatenAt: now, items: [invalid]))
        XCTAssertThrowsError(try factory.meal(eatenAt: now, items: []))
        let pasta = MealItem(nameSnapshot: "Pasta", grams: 100, amount: 100, unit: .g, carbs: 31, protein: 6, fat: 1, calories: 158)
        XCTAssertEqual(try factory.meal(eatenAt: now, items: [pasta]).meal?.totalCarbs, 31)
    }

    func testBatchIsAtomicAndRequiresInput() throws {
        let factory = EntryFactory(now: now, timeZone: utc)
        XCTAssertThrowsError(try factory.batch(.init(occurredAt: now), profiles: []))
        // Rapid insulin without profile fails the whole batch: nothing to persist.
        XCTAssertThrowsError(try factory.batch(.init(occurredAt: now, glucose: 6.8, rapidUnits: 1.5), profiles: []))
        let profile = try personalProfile()
        let result = try factory.batch(.init(occurredAt: now, glucose: 6.8, manualCarbs: 40, rapidUnits: 4, basalUnits: 12,
                                             activityName: "Ходьба", activityMinutes: 20, cycleStart: LocalDate(iso: "2026-10-01"),
                                             note: "Запись"), profiles: [profile])
        XCTAssertEqual(result.entries.map(\.kind), [.glucose, .meal, .insulin, .insulin, .activity, .note])
        XCTAssertEqual(result.count, 7)
        XCTAssertEqual(result.meal?.data.double("total_carbs"), 40)
        XCTAssertThrowsError(try factory.batch(.init(occurredAt: now, activityName: "Ходьба"), profiles: []))
    }

    func testCycleValidation() throws {
        let factory = EntryFactory(now: now, timeZone: moscow)
        XCTAssertThrowsError(try factory.cycle(start: LocalDate(iso: "2026-10-03")!))
        XCTAssertThrowsError(try factory.cycle(start: LocalDate(iso: "2026-09-01")!, length: 14))
        XCTAssertThrowsError(try factory.cycle(start: LocalDate(iso: "2026-09-01")!, ovulation: LocalDate(iso: "2026-08-30")))
        XCTAssertEqual(try factory.cycle(start: LocalDate(iso: "2026-09-20")!).cycleLength, 28)
    }

    // MARK: Bolus workflow

    func testPersonalStepSnapshotAndConfirmation() throws {
        let profile = try personalProfile()
        let request = BolusWorkflow.Request(glucose: 6, unit: .mmol, carbs: 35, measuredAt: now)
        let calc = try BolusWorkflow.calculate(request, profile: profile, insulinEntries: [], now: now, timeZone: moscow)
        XCTAssertEqual(calc.result?.recommendedBolus, 3)
        XCTAssertEqual(calc.result?.unroundedBolus, 3.5)
        XCTAssertEqual(calc.result?.roundingIncrement, 1)
        XCTAssertEqual(calc.input?.insulinID, "fiasp")
        XCTAssertEqual(calc.input?.bolusIncrement, 1)
        XCTAssertEqual(calc.input?.profileVersion, profile.version)
        XCTAssertEqual(calc.algorithmVersion, "bolus-v1.1.0")
        XCTAssertThrowsError(try BolusWorkflow.confirm(calc, actualUnits: 3.5, administeredAt: now, now: now, profiles: [profile]))
        // A later profile version with step 0.5 never changes the saved step.
        var newer = try personalProfile(step: 0.5)
        newer.version = 2
        XCTAssertThrowsError(try BolusWorkflow.confirm(calc, actualUnits: 3.5, administeredAt: now, now: now, profiles: [profile, newer]))
        guard case .confirmed(let entry, let confirmed) = try BolusWorkflow.confirm(calc, actualUnits: 3, administeredAt: now, now: now, profiles: [profile]) else {
            return XCTFail("expected confirmation")
        }
        XCTAssertEqual(confirmed.actualBolus, 3)
        XCTAssertEqual(confirmed.confirmedEntryID, entry.id)
        XCTAssertEqual(entry.insulin?.purpose, .mealAndCorrection)
        XCTAssertEqual(entry.insulin?.dia, 4)
        XCTAssertEqual(entry.dedupeKey, "bolus:" + calc.id.uuidString.lowercased())
        XCTAssertEqual(confirmed.calculationSnapshot, calc.calculationSnapshot, "recommendation is immutable")
        guard case .alreadyConfirmed(let id, let units) = try BolusWorkflow.confirm(confirmed, actualUnits: 3, administeredAt: now, now: now, profiles: [profile]) else {
            return XCTFail("expected idempotent repeat")
        }
        XCTAssertEqual(id, entry.id)
        XCTAssertEqual(units, 3)
        // Only the actual dose counts for IOB; the recommendation itself never does.
        XCTAssertEqual(try BolusWorkflow.currentIOB(entries: [entry], at: now), 3)
        XCTAssertEqual(try BolusWorkflow.currentIOB(entries: [], at: now), 0)
    }

    func testIOBDecaysAndIsUsedByNextCalculation() throws {
        let profile = try personalProfile(step: 0.1)
        let factory = EntryFactory(now: now, timeZone: utc)
        let dose = try factory.insulin(units: 2.2, type: .rapid, administeredAt: now.addingTimeInterval(-3600), profiles: [profile])
        let basal = try factory.insulin(units: 20, type: .basal, purpose: .basal, administeredAt: now.addingTimeInterval(-600), profiles: [profile])
        let old = try factory.insulin(units: 5, type: .rapid, administeredAt: now.addingTimeInterval(-9 * 3600), profiles: [profile])
        XCTAssertEqual(try BolusWorkflow.currentIOB(entries: [dose, basal, old], at: now), 1.6500000000000001)
        let calc = try BolusWorkflow.calculate(.init(glucose: 10.2, unit: .mmol, carbs: 62, measuredAt: now), profile: profile,
                                               insulinEntries: [dose, basal, old], now: now, timeZone: utc)
        XCTAssertEqual(calc.input?.iob, 1.6500000000000001)
        XCTAssertEqual(calc.result?.recommendedBolus, 6.6)
    }

    func testBlockedCalculationsCannotBeConfirmed() throws {
        let profile = try personalProfile()
        let stale = try BolusWorkflow.calculate(.init(glucose: 10, unit: .mmol, carbs: 50, measuredAt: now.addingTimeInterval(-3600)),
                                                profile: profile, insulinEntries: [], now: now, timeZone: utc)
        XCTAssertEqual(stale.result?.calculationStatus, .blocked)
        XCTAssertEqual(stale.result?.warnings, ["stale_glucose"])
        XCTAssertThrowsError(try BolusWorkflow.confirm(stale, actualUnits: 1, administeredAt: now, now: now, profiles: [profile]))
        let fresh = try BolusWorkflow.calculate(.init(glucose: 10, unit: .mmol, carbs: 50, measuredAt: now), profile: profile,
                                                insulinEntries: [], now: now, timeZone: utc)
        XCTAssertThrowsError(try BolusWorkflow.confirm(fresh, actualUnits: 2, administeredAt: now, now: now.addingTimeInterval(901), profiles: [profile]))
        XCTAssertThrowsError(try BolusWorkflow.confirm(fresh, actualUnits: 16, administeredAt: now, now: now, profiles: [profile]))
        XCTAssertThrowsError(try BolusWorkflow.confirm(fresh, actualUnits: 2, administeredAt: now.addingTimeInterval(-120), now: now, profiles: [profile]))
    }

    func testMgdlGivesSameResultAndUnconfirmedProfileBlocks() throws {
        let profile = try personalProfile(step: 0.1)
        let a = try BolusWorkflow.calculate(.init(glucose: 10, unit: .mmol, carbs: 50, measuredAt: now), profile: profile, insulinEntries: [], now: now, timeZone: utc)
        let b = try BolusWorkflow.calculate(.init(glucose: 180, unit: .mgdl, carbs: 50, measuredAt: now), profile: profile, insulinEntries: [], now: now, timeZone: utc)
        XCTAssertEqual(a.result?.recommendedBolus, b.result?.recommendedBolus)
        XCTAssertEqual(b.input?.originalUnit, "mg/dL")
        var unconfirmed = profile
        unconfirmed.settings.confirmed = false
        XCTAssertThrowsError(try BolusWorkflow.calculate(.init(glucose: 10, unit: .mmol, carbs: 50, measuredAt: now), profile: unconfirmed, insulinEntries: [], now: now, timeZone: utc))
        XCTAssertThrowsError(try BolusWorkflow.calculate(.init(glucose: 10, unit: .mmol, carbs: 50, measuredAt: now), profile: nil, insulinEntries: [], now: now, timeZone: utc))
    }

    func testMealCarbsComeFromStoredMealAndSegmentsUseTimeZone() throws {
        var settings = try personalProfile(step: 0.1).settings
        settings.segments = [TherapySegment(startTime: "00:00", endTime: "15:00", icr: 10, isf: 2, target: 6, correctAbove: 7),
                             TherapySegment(startTime: "15:00", endTime: "24:00", icr: 5, isf: 2, target: 6, correctAbove: 7)]
        let profile = try ProfileWorkflow.newVersion(settings, existing: [], now: now.addingTimeInterval(-60)).profile
        let meal = try EntryFactory(now: now, timeZone: utc).meal(eatenAt: now, items: [MealItem(nameSnapshot: "Rice", grams: 150, amount: 150, unit: .g, carbs: 42.3)])
        let request = BolusWorkflow.Request(glucose: 6, unit: .mmol, carbs: 999, measuredAt: now, meal: meal)
        let inUTC = try BolusWorkflow.calculate(request, profile: profile, insulinEntries: [], now: now, timeZone: utc)
        let inMoscow = try BolusWorkflow.calculate(request, profile: profile, insulinEntries: [], now: now, timeZone: moscow)
        XCTAssertEqual(inUTC.input?.carbs, 42.3)
        XCTAssertEqual(inUTC.input?.mealID, meal.id.uuidString.lowercased())
        XCTAssertEqual(inUTC.result?.recommendedBolus, 4.2)
        XCTAssertEqual(inMoscow.input?.startTime, "15:00")
        XCTAssertEqual(inMoscow.result?.recommendedBolus, 8.4)
    }

    func testProfileVersioningNeverRewritesHistory() throws {
        let first = try personalProfile()
        var settings = first.settings
        settings.segments[0].icr = 13
        let (second, archived) = try ProfileWorkflow.newVersion(settings, existing: [first], now: now)
        XCTAssertEqual(second.version, 2)
        XCTAssertEqual(archived?.status, "archived")
        XCTAssertEqual(archived?.validTo, now)
        XCTAssertEqual(archived?.settings.segments[0].icr, 10)
        XCTAssertEqual(archived?.settings, first.settings)
        settings.segments[0].endTime = "05:00"
        XCTAssertThrowsError(try ProfileWorkflow.newVersion(settings, existing: [first], now: now))
        settings.segments[0].endTime = "24:00"
        settings.confirmed = false
        XCTAssertThrowsError(try ProfileWorkflow.newVersion(settings, existing: [first], now: now))
        settings.confirmed = true
        settings.bolusIncrement = 0.3
        XCTAssertThrowsError(try ProfileWorkflow.newVersion(settings, existing: [first], now: now))
        // An insulin entry uses the profile valid at its administration time.
        XCTAssertEqual(EntryFactory.profile(at: now.addingTimeInterval(-60), in: [first, second])?.version, 1)
        XCTAssertEqual(EntryFactory.profile(at: now.addingTimeInterval(60), in: [first, second])?.version, 2)
    }

    // MARK: HealthKit

    func healthPayload(steps: Int? = 4000, exercise: Double? = 55) -> HealthPayload {
        let workout = HealthWorkout(id: "8F4C3A5E-1B2D-4C6E-9F00-112233445566", name: "Ходьба", sourceName: "Apple Watch",
                                    startedAt: now.addingTimeInterval(-3600), endedAt: now, durationMinutes: 55, activeEnergy: 150, distanceKm: nil)
        return HealthPayload(timezone: "Europe/Moscow", workouts: [workout],
                             days: [HealthDay(date: "2026-10-02", steps: steps, exerciseMinutes: exercise)])
    }

    func apply(_ plan: HealthImportPlanner.Plan, to store: inout [String: DiaryRecord]) {
        for record in plan.inserts + plan.updates { store[record.dedupeKey!] = record }
    }

    func testHealthSyncUpsertsWithoutDuplicates() throws {
        var store: [String: DiaryRecord] = [:]
        let first = try HealthImportPlanner.plan(healthPayload(), existing: store, now: now)
        XCTAssertEqual(first.inserted, 2)
        apply(first, to: &store)
        let workout = try XCTUnwrap(store["healthkit-workout:8f4c3a5e-1b2d-4c6e-9f00-112233445566"])
        XCTAssertEqual(workout.clientID, UUID(uuidString: "8F4C3A5E-1B2D-4C6E-9F00-112233445566"))
        XCTAssertEqual(workout.data.string("external_id"), "8f4c3a5e-1b2d-4c6e-9f00-112233445566")
        XCTAssertNil(workout.data["distance_km"])
        let second = try HealthImportPlanner.plan(healthPayload(), existing: store, now: now)
        XCTAssertEqual(second.unchanged, 2)
        XCTAssertEqual(second.inserted + second.updated, 0)
        let third = try HealthImportPlanner.plan(healthPayload(steps: 5000), existing: store, now: now)
        XCTAssertEqual(third.updated, 1)
        XCTAssertEqual(third.updates.first?.version, 2)
    }

    func testMissingPermissionsAreNotFabricated() throws {
        var store: [String: DiaryRecord] = [:]
        apply(try HealthImportPlanner.plan(healthPayload(steps: 120, exercise: nil), existing: store, now: now), to: &store)
        let day = try XCTUnwrap(store["healthkit-day:2026-10-02"])
        XCTAssertEqual(day.data.double("steps"), 120)
        XCTAssertNil(day.data["exercise_minutes"])
        XCTAssertEqual(day.occurredAt, date("2026-10-01T21:00:00Z"))
        apply(try HealthImportPlanner.plan(healthPayload(steps: nil, exercise: 5), existing: store, now: now), to: &store)
        let merged = try XCTUnwrap(store["healthkit-day:2026-10-02"])
        XCTAssertEqual(merged.data.double("steps"), 120)
        XCTAssertEqual(merged.data.double("exercise_minutes"), 5)
    }

    func testHealthValidation() {
        var payload = healthPayload()
        payload.days[0].steps = -1
        XCTAssertThrowsError(try HealthImportPlanner.plan(payload, existing: [:], now: now))
        payload = healthPayload()
        payload.days[0].date = "2999-01-01"
        XCTAssertThrowsError(try HealthImportPlanner.plan(payload, existing: [:], now: now))
        payload = healthPayload()
        payload.workouts.append(payload.workouts[0])
        XCTAssertThrowsError(try HealthImportPlanner.plan(payload, existing: [:], now: now))
        payload = healthPayload()
        payload.days = [HealthDay(date: "2026-10-01")]
        XCTAssertThrowsError(try HealthImportPlanner.plan(payload, existing: [:], now: now))
        payload = healthPayload()
        payload.days = []
        XCTAssertEqual(try HealthImportPlanner.plan(payload, existing: [:], now: now).inserted, 1)
    }

    func testRecordsRoundTripThroughJSON() throws {
        let entry = try EntryFactory(now: now, timeZone: utc).glucose(value: 6.8, unit: .mmol, measuredAt: date("2026-10-02T11:59:00.123456Z"))
        let decoded = try BolusJSON.decoder.decode(DiaryRecord.self, from: BolusJSON.encoder.encode(entry))
        XCTAssertEqual(decoded, entry)
        let profile = try personalProfile()
        XCTAssertEqual(try BolusJSON.decoder.decode(TherapyProfileRecord.self, from: BolusJSON.encoder.encode(profile)), profile)
    }
}
