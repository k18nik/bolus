import XCTest
@testable import BolusCore

/// Corrections of saved entries: identity kept, version raised, same validation as new entries.
final class EntryEditorTests: XCTestCase {
    let utc = TimeZone(identifier: "UTC")!
    var factory: EntryFactory { EntryFactory(now: referenceInstant, timeZone: utc) }
    var editor: EntryEditor { EntryEditor(now: referenceInstant.addingTimeInterval(120), timeZone: utc) }

    func profile(step: Double) throws -> TherapyProfileRecord {
        let settings = TherapySettings(rapidInsulinName: "Фиасп", basalInsulinName: "Тресиба", bolusIncrement: step, basalIncrement: 1,
                                       maxBolus: 15, insulinActionDuration: 4,
                                       segments: [TherapySegment(startTime: "00:00", endTime: "24:00", icr: 10, isf: 2, target: 6, correctAbove: 7)],
                                       confirmed: true)
        var profile = try ProfileWorkflow.newVersion(settings, existing: [], now: referenceInstant.addingTimeInterval(-86400)).profile
        profile.validFrom = referenceInstant.addingTimeInterval(-86400)
        return profile
    }

    func testGlucoseCorrectionKeepsIdentityAndRaisesVersion() throws {
        let original = try factory.glucose(value: 7.2, unit: .mmol, measuredAt: referenceInstant)
        let earlier = referenceInstant.addingTimeInterval(-300)
        let edited = try editor.glucose(original, value: 7.8, unit: .mmol, measuredAt: earlier, note: "после кофе")
        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.clientID, original.clientID)
        XCTAssertEqual(edited.createdAt, original.createdAt)
        XCTAssertEqual(edited.version, original.version + 1)
        XCTAssertEqual(edited.updatedAt, referenceInstant.addingTimeInterval(120))
        XCTAssertEqual(edited.occurredAt, earlier)
        XCTAssertEqual(edited.data.double("value_mmol"), 7.8)
        XCTAssertEqual(edited.noteText, "после кофе")
        XCTAssertThrowsError(try editor.glucose(original, value: 0, unit: .mmol, measuredAt: referenceInstant, note: ""))
        XCTAssertThrowsError(try editor.glucose(original, value: 7, unit: .mmol, measuredAt: referenceInstant.addingTimeInterval(3600), note: ""))
    }

    func testInsulinCorrectionKeepsDIAStepAndLink() throws {
        let original = try factory.insulin(units: 3, type: .rapid, administeredAt: referenceInstant, profiles: [try profile(step: 0.5)])
        let edited = try editor.insulin(original, units: 2.5, administeredAt: referenceInstant.addingTimeInterval(-60), note: "опечатка")
        XCTAssertEqual(edited.insulin?.units, 2.5)
        XCTAssertEqual(edited.insulin?.dia, 4)
        XCTAssertEqual(edited.insulin?.doseIncrement, 0.5)
        XCTAssertEqual(edited.insulin?.actionModel, IOBEngine.modelVersion)
        XCTAssertEqual(edited.noteText, "опечатка")
        XCTAssertThrowsError(try editor.insulin(original, units: 2.3, administeredAt: referenceInstant, note: ""), "not a multiple of the step")
        XCTAssertThrowsError(try editor.insulin(original, units: 6, administeredAt: referenceInstant, note: "", maxUnits: 5))
        XCTAssertThrowsError(try editor.insulin(original, units: .nan, administeredAt: referenceInstant, note: ""))
    }

    func testMealCorrectionRescalesTheSnapshot() throws {
        let pasta = MealItem(nameSnapshot: "Паста", grams: 200, amount: 200, unit: .g, carbs: 62, protein: 10, fat: 2, calories: 300, fiber: 4)
        let original = try factory.meal(eatenAt: referenceInstant, items: [pasta])
        let half = pasta.rescaled(to: 100)
        XCTAssertEqual(half.carbs, 31)
        XCTAssertEqual(half.grams, 100)
        XCTAssertEqual(half.fiber, 2)
        XCTAssertNil(half.sugar, "unknown stays unknown")
        let edited = try editor.meal(original, name: "Ужин", mealType: .dinner, eatenAt: referenceInstant, items: [half], note: "")
        XCTAssertEqual(edited.meal?.totalCarbs, 31)
        XCTAssertEqual(edited.meal?.name, "Ужин")
        XCTAssertEqual(edited.meal?.mealType, .dinner)
        let juice = MealItem(nameSnapshot: "Сок", grams: nil, amount: 200, unit: .ml, carbs: 20)
        XCTAssertNil(juice.rescaled(to: 300).grams, "density is never invented")
        XCTAssertEqual(juice.rescaled(to: 300).carbs, 30)
        XCTAssertThrowsError(try editor.meal(original, name: "Ужин", mealType: .dinner, eatenAt: referenceInstant, items: [], note: ""))
    }

    func testManualCarbsLineIsRecognised() throws {
        let batch = try factory.batch(.init(occurredAt: referenceInstant, manualCarbs: 45), profiles: [])
        XCTAssertEqual(batch.meal?.meal?.items.first?.isManualCarbs, true)
    }

    func testAppleHealthDataIsNotEditedByHand() throws {
        let workout = DiaryRecord(kind: .activity, occurredAt: referenceInstant,
                                  data: .object(["name": .string("Бег"), "duration_minutes": .number(30.5), "source": .string("apple_health")]))
        XCTAssertFalse(EntryEditor.isEditable(workout))
        XCTAssertThrowsError(try editor.activity(workout, name: "Бег", durationMinutes: 20, intensity: "moderate", occurredAt: referenceInstant, note: ""))
        let summary = DiaryRecord(kind: .activitySummary, occurredAt: referenceInstant, data: .object(["steps": .number(5000)]))
        XCTAssertFalse(EntryEditor.isEditable(summary))
        let walk = try factory.activity(name: "Ходьба", durationMinutes: 30, occurredAt: referenceInstant)
        XCTAssertTrue(EntryEditor.isEditable(walk))
        let longer = try editor.activity(walk, name: "Ходьба", durationMinutes: 45, intensity: "low", occurredAt: referenceInstant, note: "")
        XCTAssertEqual(longer.activity?.durationMinutes, 45)
        XCTAssertEqual(longer.activity?.intensity, "low")
        let note = try factory.note("Первая версия", occurredAt: referenceInstant)
        XCTAssertEqual(try editor.note(note, text: "Исправлено", occurredAt: referenceInstant).noteText, "Исправлено")
        XCTAssertThrowsError(try editor.note(note, text: "  ", occurredAt: referenceInstant))
        XCTAssertThrowsError(try editor.glucose(note, value: 6, unit: .mmol, measuredAt: referenceInstant, note: ""), "kind must match")
    }
}
