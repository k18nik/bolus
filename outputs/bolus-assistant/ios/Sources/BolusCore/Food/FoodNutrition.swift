import Foundation

/// Offline food logic: nutrition snapshots, recipes, recent foods and local search.
public enum FoodNutrition {
    /// Web `makeItem(food, amount)`: nutrients scale with `amount / serving_weight`.
    /// Liquids keep `ml` with `grams = nil`; unknown fiber/sugar stay unknown.
    public static func item(from food: FoodRecord, amount: Double) -> MealItem {
        let scale = amount / (food.servingWeight > 0 ? food.servingWeight : 100)
        let unit: MealItemUnit = food.baseUnit == "ml" ? .ml : .g
        return MealItem(nameSnapshot: food.name, foodSource: food.source, foodID: food.externalID ?? food.id.uuidString.lowercased(),
                        grams: unit == .g ? amount : nil, amount: amount, unit: unit,
                        carbs: food.carbs * scale, protein: food.protein * scale, fat: food.fat * scale,
                        calories: food.calories * scale, fiber: food.fiber.map { $0 * scale }, sugar: food.sugar.map { $0 * scale })
    }

    /// Validated custom product (`FoodInput`): nutrients per serving of `servingWeight`.
    public static func customFood(name: String, brand: String = "", baseUnit: String = "g", servingName: String? = nil,
                                  servingWeight: Double = 100, carbs: Double, protein: Double = 0, fat: Double = 0,
                                  calories: Double = 0, fiber: Double? = nil, sugar: Double? = nil, barcode: String? = nil,
                                  now: Date = Date()) throws -> FoodRecord {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 150 else { throw BolusError.validation("Укажите название продукта") }
        guard brand.count <= 100 else { throw BolusError.validation("Бренд длиннее 100 символов") }
        guard ["g", "ml"].contains(baseUnit) else { throw BolusError.validation("Единица: граммы или миллилитры") }
        guard servingWeight.isFinite, servingWeight > 0, servingWeight <= 10000 else { throw BolusError.validation("Вес порции: от 0 до 10 000") }
        let required = [carbs, protein, fat, calories]
        guard required.allSatisfy({ $0.isFinite && $0 >= 0 }), carbs <= 1000, protein <= 1000, fat <= 1000, calories <= 10000 else {
            throw BolusError.validation("Проверьте пищевую ценность")
        }
        for value in [fiber, sugar] {
            if let value, !(value.isFinite && value >= 0 && value <= 1000) { throw BolusError.validation("Проверьте клетчатку и сахар") }
        }
        let serving = servingName?.trimmingCharacters(in: .whitespaces).isEmpty == false
            ? servingName! : BolusFormat.number(servingWeight) + (baseUnit == "ml" ? " мл" : " г")
        return FoodRecord(name: title, brand: brand, source: "custom", baseUnit: baseUnit, servingName: String(serving.prefix(80)),
                          servingWeight: servingWeight, carbs: carbs, protein: protein, fat: fat, calories: calories,
                          fiber: fiber, sugar: sugar, barcode: barcode, createdAt: now)
    }

    /// Port of `POST /recipes`: totals of known values; per-100 g of the cooked dish
    /// and per serving rounded to 4 digits. Fiber/sugar are unknown if any ingredient lacks them.
    public static func recipe(name: String, ingredients: [MealItem], cookedWeight: Double, servings: Int, now: Date = Date()) throws -> FoodRecord {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 150 else { throw BolusError.validation("Укажите название блюда") }
        guard !ingredients.isEmpty, ingredients.count <= 100 else { throw BolusError.validation("Добавьте ингредиенты") }
        try ingredients.forEach(EntryFactory.validate(item:))
        guard cookedWeight.isFinite, cookedWeight > 0, cookedWeight <= 50000 else { throw BolusError.validation("Вес готового блюда: от 0 до 50 000 г") }
        guard (1...100).contains(servings) else { throw BolusError.validation("Число порций: от 1 до 100") }
        func total(_ value: (MealItem) -> Double?) -> Double? {
            let values = ingredients.map(value)
            guard values.allSatisfy({ $0 != nil }) else { return nil }
            return values.reduce(0) { $0 + $1! }
        }
        let totals = NutrientTotals(carbs: total { $0.carbs }, protein: total { $0.protein }, fat: total { $0.fat },
                                    calories: total { $0.calories }, fiber: total { $0.fiber }, sugar: total { $0.sugar })
        func per100(_ value: Double?) -> Double? { value.map { PyFloat.round($0 / cookedWeight * 100, 4) } }
        func perServing(_ value: Double?) -> Double? { value.map { PyFloat.round($0 / Double(servings), 4) } }
        let definition = RecipeDefinition(
            ingredients: ingredients, cookedWeight: cookedWeight, servings: servings, total: totals,
            perServing: NutrientTotals(carbs: perServing(totals.carbs), protein: perServing(totals.protein), fat: perServing(totals.fat),
                                       calories: perServing(totals.calories), fiber: perServing(totals.fiber), sugar: perServing(totals.sugar)))
        return FoodRecord(name: title, brand: "Мои блюда", source: "recipe", baseUnit: "g", servingName: "100 г", servingWeight: 100,
                          carbs: per100(totals.carbs) ?? 0, protein: per100(totals.protein) ?? 0, fat: per100(totals.fat) ?? 0,
                          calories: per100(totals.calories) ?? 0, fiber: per100(totals.fiber), sugar: per100(totals.sugar),
                          isRecipe: true, recipe: definition, createdAt: now)
    }

    /// Port of `GET /foods/recent`: unique items of the 30 latest meals, per 100 g/ml.
    public static func recentFoods(from meals: [DiaryRecord], limit: Int = 20) -> [FoodRecord] {
        var seen = Set<String>()
        var result: [FoodRecord] = []
        let latest = meals.filter { $0.kind == .meal }.sorted { $0.occurredAt > $1.occurredAt }.prefix(30)
        for entry in latest {
            for item in entry.meal?.items ?? [] {
                let key = item.foodSource + "\u{1F}" + item.foodID + "\u{1F}" + item.nameSnapshot
                if seen.contains(key) { continue }
                seen.insert(key)
                let isLiquid = item.unit == .ml
                let quantity = isLiquid ? item.amount : (item.grams ?? 100)
                guard quantity != 0 else { continue }
                func per100(_ value: Double) -> Double { PyFloat.round(value / quantity * 100, 4) }
                result.append(FoodRecord(
                    id: UUID(), name: item.nameSnapshot, brand: "Недавно в дневнике",
                    source: item.foodSource.isEmpty ? "snapshot" : item.foodSource,
                    externalID: item.foodID.isEmpty ? entry.id.uuidString.lowercased() : item.foodID,
                    baseUnit: isLiquid ? "ml" : "g", servingName: isLiquid ? "100 мл" : "100 г", servingWeight: 100,
                    carbs: per100(item.carbs), protein: per100(item.protein), fat: per100(item.fat), calories: per100(item.calories),
                    fiber: item.fiber.map(per100), sugar: item.sugar.map(per100), createdAt: entry.occurredAt, lastUsedAt: entry.occurredAt))
            }
        }
        return Array(result.prefix(limit))
    }

    /// Case-insensitive local search (works offline).
    public static func filter(_ foods: [FoodRecord], query: String) -> [FoodRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return foods }
        return foods.filter { $0.name.lowercased().contains(q) || $0.brand.lowercased().contains(q) }
    }

    public static func totals(_ items: [MealItem]) -> NutrientTotals {
        func sum(_ value: (MealItem) -> Double?) -> Double? {
            let values = items.map(value)
            return values.contains { $0 == nil } ? nil : values.reduce(0) { $0 + $1! }
        }
        return NutrientTotals(carbs: sum { $0.carbs }, protein: sum { $0.protein }, fat: sum { $0.fat },
                              calories: sum { $0.calories }, fiber: sum { $0.fiber }, sugar: sum { $0.sugar })
    }
}
