import XCTest
@testable import BolusCore

/// Ports of `backend/tests/test_yazio.py` and the AI tests of `test_personal_mode.py`.
final class FoodTests: XCTestCase {
    func product(unit: String = "g", _ changes: [String: JSONValue] = [:]) -> JSONValue {
        var object: [String: JSONValue] = [
            "product_id": .string("catalog-1"), "name": .string(unit == "g" ? "Макароны" : "Кола"), "producer": .null,
            "base_unit": .string(unit), "serving": .string("cup"), "amount": .number(140), "serving_quantity": .number(1),
            "is_verified": .bool(true),
            "nutrients": .object(["energy.energy": .number(1.58), "nutrient.carb": .number(0.3086), "nutrient.protein": .number(0.058),
                                  "nutrient.fat": .number(0.0093)]),
        ]
        for (key, value) in changes { object[key] = value }
        return .object(object)
    }

    func testPerUnitNotPerServingAndNoUnknownZero() throws {
        let food = try YazioCatalog.normalize(product())
        XCTAssertEqual(food.carbs, 30.86)
        XCTAssertEqual(food.calories, 158)
        XCTAssertEqual(food.protein, 5.8)
        XCTAssertEqual(food.servingWeight, 100)
        XCTAssertEqual(food.baseUnit, "g")
        XCTAssertNil(food.fiber)
        XCTAssertNil(food.sugar)
        XCTAssertEqual(try YazioCatalog.normalize(product(["amount": .number(9000)])), food)
        var nutrients = product()["nutrients"]!.objectValue!
        nutrients["nutrient.carb"] = .number(0)
        XCTAssertEqual(try YazioCatalog.normalize(product(["nutrients": .object(nutrients)])).carbs, 0)
    }

    func testBadCarbsAreNotTurnedIntoZero() {
        for value: JSONValue in [.null, .bool(true), .string("NaN"), .number(.infinity), .number(-0.2), .string("bad"), .number(2)] {
            var nutrients = product()["nutrients"]!.objectValue!
            nutrients["nutrient.carb"] = value
            XCTAssertThrowsError(try YazioCatalog.normalize(product(["nutrients": .object(nutrients)])), "\(value)")
        }
    }

    func testIncompleteOrUnknownBasisRejected() {
        for change: [String: JSONValue] in [["base_unit": .string("oz")], ["nutrients": .object([:])], ["name": .string("")], ["product_id": .null]] {
            XCTAssertThrowsError(try YazioCatalog.normalize(product(change)))
        }
    }

    func testPublicSearchContractAndInvalidProductIsolation() async throws {
        let recorder = RequestRecorder()
        let body = try BolusJSON.encoder.encode(JSONValue.array([product(), product(), product(["product_id": .string("bad"), "nutrients": .object([:])])]))
        let result = await FoodCatalogSearch.search("Макароны", options: .init(), transport: recorder.respond(200, body))
        XCTAssertEqual(result.foods.count, 1)
        XCTAssertEqual(result.foods.first?.provider, "yazio")
        XCTAssertEqual(result.warnings, [YazioCatalog.skippedWarning])
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url.host, "yzapi.yazio.com")
        XCTAssertEqual(request.url.path, "/v15/products/search")
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }),
                       ["query": "Макароны", "countries": "RU", "locales": "ru_RU", "sex": "male"])
        XCTAssertEqual(request.method, "GET")
        XCTAssertNil(request.headers["Authorization"])
        XCTAssertNil(request.body)
    }

    func testShortQueriesNeverCallTheNetwork() async {
        let recorder = RequestRecorder()
        for query in ["", " ", "м"] {
            let result = await FoodCatalogSearch.search(query, options: .init(), transport: recorder.respond(200, Data()))
            XCTAssertTrue(result.foods.isEmpty && result.warnings.isEmpty)
        }
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testFailuresAreVisibleAndOfflineIsNotFatal() async {
        for status in [301, 400, 401, 403, 429, 500] {
            let result = await FoodCatalogSearch.search("Макароны", options: .init(), transport: RequestRecorder().respond(status, Data("private-debug-text".utf8)))
            XCTAssertTrue(result.foods.isEmpty)
            XCTAssertFalse(result.warnings.isEmpty)
            XCTAssertFalse(result.warnings.joined().contains("private-debug-text"))
        }
        let offline = await FoodCatalogSearch.search("Макароны", options: .init(), transport: { _ in throw URLError(.notConnectedToInternet) })
        XCTAssertEqual(offline.warnings, ["YAZIO временно не отвечает. Повторите поиск позже."])
        let changed = await FoodCatalogSearch.search("food", options: .init(), transport: RequestRecorder().respond(200, Data(#"{"items":[]}"#.utf8)))
        XCTAssertTrue(changed.warnings.first?.contains("Формат") ?? false)
    }

    func testExplicitUSDAFallback() async {
        let recorder = RequestRecorder()
        let transport: HTTPTransport = { request in
            recorder.record(request)
            if request.url.host == "yzapi.yazio.com" { return HTTPResponseData(status: 503, body: Data()) }
            return HTTPResponseData(status: 200, body: Data(#"{"foods":[{"fdcId":1,"description":"Rice","foodNutrients":[{"nutrientId":1005,"value":28}]},{"fdcId":2,"description":"No carbs info","foodNutrients":[]}]}"#.utf8))
        }
        let result = await FoodCatalogSearch.search("rice", options: .init(usdaKey: "test-usda"), transport: transport)
        XCTAssertEqual(recorder.requests.map { $0.url.host ?? "" }, ["yzapi.yazio.com", "api.nal.usda.gov"])
        XCTAssertEqual(result.foods.map(\.provider), ["usda"])
        XCTAssertEqual(result.foods.first?.carbs, 28)
        XCTAssertNil(result.foods.first?.fiber)
        XCTAssertTrue(result.warnings.contains { $0.contains("USDA") })
    }

    func testLiquidSnapshotRecentsRecipeAndHistoryImmutability() throws {
        let now = referenceInstant
        var cola = try YazioCatalog.normalize(product(unit: "ml", ["nutrients": .object(["energy.energy": .number(0.41), "nutrient.carb": .number(0.1058),
                                                                                    "nutrient.protein": .number(0), "nutrient.fat": .number(0)])]))
        XCTAssertEqual(cola.carbs, 10.58)
        let saved = cola.toFoodRecord(now: now)
        let item = FoodNutrition.item(from: saved, amount: 250)
        let meal = try EntryFactory(now: now, timeZone: TimeZone(identifier: "UTC")!).meal(name: "Напиток", eatenAt: now, items: [item])
        XCTAssertEqual(meal.meal?.totalCarbs, 26.45)
        XCTAssertNil(meal.meal?.items.first?.grams)
        let recent = try XCTUnwrap(FoodNutrition.recentFoods(from: [meal]).first)
        XCTAssertEqual(recent.baseUnit, "ml")
        XCTAssertEqual(recent.carbs, 10.58)
        XCTAssertNil(recent.fiber)
        let recipe = try FoodNutrition.recipe(name: "Напиток в рецепте", ingredients: [item], cookedWeight: 300, servings: 2, now: now)
        XCTAssertEqual(recipe.carbs, 8.8167)
        XCTAssertNil(recipe.fiber)
        // Changing the catalog product never changes the stored meal snapshot.
        cola.carbs = 90
        XCTAssertEqual(meal.meal?.totalCarbs, 26.45)
    }

    func testRecipeTotalsAndCustomFood() throws {
        let pasta = MealItem(nameSnapshot: "Pasta", grams: 100, amount: 100, unit: .g, carbs: 31, protein: 6, fat: 1, calories: 158)
        let recipe = try FoodNutrition.recipe(name: "Double", ingredients: [pasta, pasta], cookedWeight: 250, servings: 2)
        XCTAssertEqual(recipe.carbs, 24.8)
        XCTAssertEqual(recipe.recipe?.perServing.carbs, 31)
        XCTAssertEqual(recipe.source, "recipe")
        XCTAssertThrowsError(try FoodNutrition.recipe(name: "", ingredients: [pasta], cookedWeight: 250, servings: 2))
        let custom = try FoodNutrition.customFood(name: "Сырник", servingName: "1 шт", servingWeight: 60, carbs: 14.2, protein: 9, fat: 6, calories: 150)
        let item = FoodNutrition.item(from: custom, amount: 120)
        XCTAssertEqual(item.carbs, 28.4)
        XCTAssertEqual(item.grams, 120)
        XCTAssertThrowsError(try FoodNutrition.customFood(name: "X", carbs: -1))
        XCTAssertEqual(FoodNutrition.filter([custom, recipe], query: "сыр").map(\.name), ["Сырник"])
    }
}

/// Collects requests for assertions (thread-safe for async transports).
final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [HTTPRequestSpec] = []

    var requests: [HTTPRequestSpec] { lock.lock(); defer { lock.unlock() }; return storage }

    func record(_ request: HTTPRequestSpec) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }

    func respond(_ status: Int, _ body: Data) -> HTTPTransport {
        { request in
            self.record(request)
            return HTTPResponseData(status: status, body: body)
        }
    }
}

final class AITests: XCTestCase {
    func insight(_ changes: [String: JSONValue] = [:]) -> JSONValue {
        var object: [String: JSONValue] = [
            "summary": .string("Наблюдений пока мало."), "observations": .array([.string("Записанные значения требуют сопоставления с едой.")]),
            "possible_explanations": .array([]), "questions": .array([.string("Есть ли измерения после тренировки?")]),
            "safety_flags": .array([.string("Ручные измерения не отражают весь день.")]),
        ]
        for (key, value) in changes { object[key] = value }
        return .object(object)
    }

    func completed(_ text: String, tokens: Double = 153) -> Data {
        try! BolusJSON.encoder.encode(JSONValue.object([
            "status": .string("completed"),
            "output": .array([.object(["type": .string("message"), "content": .array([.object(["type": .string("output_text"), "text": .string(text)])])])]),
            "usage": .object(["input_tokens": .number(111), "output_tokens": .number(42), "total_tokens": .number(tokens)]),
        ]))
    }

    func testContractAggregateContextAndNoDoseFields() async throws {
        let recorder = RequestRecorder()
        let text = String(decoding: try BolusJSON.encoder.encode(insight()), as: UTF8.self)
        let entries = [
            DiaryRecord(kind: .note, occurredAt: referenceInstant, data: .object(["note": .string("PRIVATE NOTE")])),
            DiaryRecord(kind: .glucose, occurredAt: referenceInstant, data: try JSONValue.encode(GlucosePayload(value: 6.2, unit: .mmol))),
        ]
        let settings = TherapySettings(maxBolus: 15, insulinActionDuration: 4,
                                       segments: [TherapySegment(startTime: "00:00", endTime: "24:00", icr: 10, isf: 2, target: 6, correctAbove: 7)], confirmed: true)
        let profile = TherapyProfileRecord(version: 1, validFrom: referenceInstant, settings: settings)
        let context = AIContextBuilder.build(entries: entries, days: 14, today: LocalDate(iso: "2026-10-02")!, timeZone: TimeZone(identifier: "UTC")!,
                                             profile: profile, latestCycle: nil, calculations: [])
        let result = try await AIAssistant.generateInsight(provider: .openai, key: "sk-test-secret-key-not-real-12345", model: "gpt-4.1-mini",
                                                           question: "Объясни расчёт", context: context, transport: recorder.respond(200, completed(text)))
        XCTAssertEqual(result.insight.summary, "Наблюдений пока мало.")
        XCTAssertEqual(result.usage.double("total_tokens"), 153)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.headers["Authorization"], "Bearer sk-test-secret-key-not-real-12345")
        let payload = try BolusJSON.decoder.decode(JSONValue.self, from: try XCTUnwrap(request.body))
        XCTAssertEqual(payload["store"], .bool(false))
        XCTAssertEqual(payload["text"]?["format"]?["strict"], .bool(true))
        XCTAssertNil(payload["tools"])
        let userContent = payload["input"]?.arrayValue?[1]["content"]?.stringValue ?? ""
        XCTAssertFalse(userContent.contains("PRIVATE NOTE"))
        XCTAssertFalse(userContent.contains("Мой дневник"))
        XCTAssertTrue(userContent.contains("fiasp") && userContent.contains("tresiba"))
        XCTAssertTrue(payload["input"]?.arrayValue?[0]["content"]?.stringValue?.contains("Точная схема JSON") ?? false)
    }

    func testRefusalTruncationAndToolsAreRejected() async {
        let bodies: [Data] = [
            try! BolusJSON.encoder.encode(JSONValue.object(["status": .string("incomplete"), "output": .array([])])),
            try! BolusJSON.encoder.encode(JSONValue.object(["status": .string("completed"), "output": .array([.object(["type": .string("function_call"), "name": .string("set_bolus")])])])),
            try! BolusJSON.encoder.encode(JSONValue.object(["status": .string("completed"), "output": .array([.object(["type": .string("message"), "content": .array([.object(["type": .string("refusal")])])])])])),
            Data("[]".utf8), Data("null".utf8),
            try! BolusJSON.encoder.encode(JSONValue.object(["status": .string("completed"), "output": .null])),
            try! BolusJSON.encoder.encode(JSONValue.object(["status": .string("completed"), "output": .array([.object(["type": .string("message"), "content": .array([.object(["type": .string("output_text"), "text": .number(42)])])])])])),
        ]
        for body in bodies {
            do {
                _ = try await AIAssistant.generateInsight(provider: .openai, key: "sk-test-secret-key-not-real-12345", model: "gpt-4.1-mini",
                                                          question: "Анализ", context: .object([:]), transport: RequestRecorder().respond(200, body))
                XCTFail("must be rejected: \(String(decoding: body, as: UTF8.self))")
            } catch {}
        }
    }

    func testForbiddenFieldsAreRejected() {
        XCTAssertThrowsError(try AIAssistant.validateExplanation(insight(["bolus_units": .number(5)])))
        XCTAssertThrowsError(try AIAssistant.validateExplanation(insight(["summary": .number(1)])))
        XCTAssertNoThrow(try AIAssistant.validateExplanation(insight()))
    }

    /// Dosing advice is removed sentence by sentence; facts from the data stay visible.
    func testScreeningKeepsFactsAndRemovesDosingAdvice() async throws {
        let answer = insight([
            "summary": .string("Глюкоза выросла после сока, выпитого при 3,5 ммоль/л. Введите 3 ЕД инсулина."),
            "observations": .array([
                .string("Болюс на еду был 6,2 ЕД, коррекция 2,1 ЕД, итог 8 ЕД."),
                .string("Глюкоза снизилась после болюса и выросла к 9 утра."),
                .string("Активность может снизить потребность в инсулине."),
                .string("Обычно хватает 3 ЕД."),
                .string("Вечером вы ввели 4 ЕД."),
            ]),
            "possible_explanations": .array([
                .string("Быстрые углеводы сока и ответный подъём после низкой глюкозы."),
                .string("Стоит увеличить базальный инсулин на ночь."),
                .string("Уменьшите базал на 20%."),
            ]),
            "questions": .array([.string("Нужно ли обсудить со специалистом ночную базальную дозу?"), .string("Можно добавить подколку?")]),
            "safety_flags": .array([.string("При 17 ммоль/л проверьте кетоны и следуйте плану, согласованному со специалистом."),
                                    .string("Take 2 units of insulin now.")]),
        ])
        let context: JSONValue = .object(["calculation": .object(["result": .object([
            "meal_bolus": .number(6.2), "correction_bolus": .number(2.1), "recommended_bolus": .number(8)])])])
        let question = "В 4 утра сахар был 3.5, я выпила сок, с 9 утра он начал расти и сейчас 17, почему? Вечером я ввела 4 ЕД."
        let screened = AIAssistant.screen(try AIAssistant.validateExplanation(answer),
                                          grounded: AIAssistant.groundedNumbers(question: question, context: context))
        XCTAssertEqual(screened.insight.summary, "Глюкоза выросла после сока, выпитого при 3,5 ммоль/л.")
        XCTAssertEqual(screened.insight.observations, ["Болюс на еду был 6,2 ЕД, коррекция 2,1 ЕД, итог 8 ЕД.",
                                                       "Глюкоза снизилась после болюса и выросла к 9 утра.",
                                                       "Активность может снизить потребность в инсулине.",
                                                       "Вечером вы ввели 4 ЕД."])
        XCTAssertEqual(screened.insight.possibleExplanations, ["Быстрые углеводы сока и ответный подъём после низкой глюкозы."])
        XCTAssertEqual(screened.insight.questions, ["Нужно ли обсудить со специалистом ночную базальную дозу?"])
        XCTAssertEqual(screened.insight.safetyFlags, ["При 17 ммоль/л проверьте кетоны и следуйте плану, согласованному со специалистом."])
        XCTAssertEqual(screened.hidden, 6)

        // A summary that is only advice is replaced; the call still succeeds with a notice.
        let onlyAdvice = String(decoding: try BolusJSON.encoder.encode(insight(["summary": .string("Введите 3 ЕД инсулина")])), as: UTF8.self)
        let result = try await AIAssistant.generateInsight(provider: .openai, key: "sk-test-secret-key-not-real-12345", model: "gpt-4.1-mini",
                                                           question: "Анализ", context: .object([:]),
                                                           transport: RequestRecorder().respond(200, completed(onlyAdvice)))
        XCTAssertEqual(result.insight.summary, AIAssistant.hiddenSummary)
        XCTAssertEqual(result.hidden, 1)
        XCTAssertEqual(result.insight.observations, ["Записанные значения требуют сопоставления с едой."])
    }

    func testProviderErrorsAreSanitized() async {
        for status in [401, 403, 404, 429, 500] {
            do {
                _ = try await AIAssistant.testConnection(provider: .tokenn, key: "sk-test-not-real-tokenn-key-12345", model: "gpt-5.5",
                                                         transport: RequestRecorder().respond(status, Data(#"{"error":{"code":"invalid_api_key","message":"sk-test-not-real-tokenn-key-12345"}}"#.utf8)))
                XCTFail("status \(status) must fail")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("sk-test"))
                if status == 401 { XCTAssertTrue(error.localizedDescription.contains("Tokenn")) }
            }
        }
    }

    func testTokennDestinationAndConnectionTest() async throws {
        let recorder = RequestRecorder()
        let usage = try await AIAssistant.testConnection(provider: .tokenn, key: "sk-test-tokenn-not-real-key-12345", model: "gpt-5.5",
                                                         transport: recorder.respond(200, completed(#"{"connected":true}"#, tokens: 15)))
        XCTAssertEqual(usage.double("total_tokens"), 15)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://api.tokenn.pro/v1/responses")
        let sent = try BolusJSON.decoder.decode(JSONValue.self, from: try XCTUnwrap(request.body))
        XCTAssertEqual(sent["reasoning"]?["effort"], .string("none"))
        XCTAssertFalse(sent["input"]?.stringValue?.contains("aggregates") ?? true)
    }

    func testKeyAndModelValidation() {
        XCTAssertNoThrow(try AIAssistant.validateKey("  sk-test-secret-key-not-real-12345 "))
        XCTAssertThrowsError(try AIAssistant.validateKey("not-a-key"))
        XCTAssertThrowsError(try AIAssistant.validateKey("sk-with space inside-123456789"))
        XCTAssertNoThrow(try AIAssistant.validateModel("gpt-5.5"))
        XCTAssertThrowsError(try AIAssistant.validateModel("claude"))
        XCTAssertThrowsError(try AIAssistant.validateModel("gpt-4o; rm -rf"))
    }

    /// Architectural rule: deterministic modules never reference AI, network or UI code.
    func testEngineSourcesDoNotDependOnAIOrNetwork() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BolusCore")
        let forbidden = ["AIAssistant", "AIProvider", "HTTPTransport", "URLSession", "SwiftUI", "SwiftData", "import UIKit", "OpenAI"]
        for folder in ["Engine", "Numerics"] {
            let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
            XCTAssertFalse(files.isEmpty)
            for file in files where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                for token in forbidden { XCTAssertFalse(text.contains(token), "\(file.lastPathComponent) mentions \(token)") }
            }
        }
    }
}
