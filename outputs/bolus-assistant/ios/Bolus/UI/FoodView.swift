import SwiftUI

enum FoodSource: String, CaseIterable, Identifiable {
    case mine, favorites, recent, recipes, catalog
    var id: String { rawValue }

    var title: String {
        switch self {
        case .mine: return "Мои"
        case .favorites: return "Избранное"
        case .recent: return "Недавние"
        case .recipes: return "Рецепты"
        case .catalog: return "Каталог"
        }
    }
}

/// A food chosen for a meal or recipe, with the editable amount.
struct PickedFood: Identifiable, Equatable {
    let id = UUID()
    var food: FoodRecord
    var amountText: String

    init(food: FoodRecord) {
        self.food = food
        amountText = BolusFormat.number(food.servingWeight)
    }

    var amount: Double? { BolusFormat.parse(amountText) }
    /// Nutrition snapshot: later changes of the food never alter saved meals.
    var item: MealItem? { amount.map { FoodNutrition.item(from: food, amount: $0) } }
}

/// Offline-first food search. Local foods always work; the external catalog is
/// queried only with network access.
struct FoodPicker: View {
    @Environment(DiaryStore.self) private var store
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.theme) private var theme
    let onPick: (FoodRecord) -> Void
    var onSelectForDetail: ((FoodRecord) -> Void)? = nil
    @State private var source: FoodSource = .mine
    @State private var query = ""
    @State private var catalog: [CatalogFood] = []
    @State private var warnings: [String] = []
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Источник", selection: $source) {
                ForEach(FoodSource.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(theme.muted)
                TextField("Продукт, блюдо или бренд", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(10)
            .background(theme.background)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.border))
            if source == .catalog && !network.isOnline {
                Notice(text: FoodCatalogSearch.offlineMessage, systemImage: "wifi.slash")
            }
            if searching { ProgressView("Ищем продукты…").frame(maxWidth: .infinity) }
            let foods = results
            if foods.isEmpty && !searching {
                Text(emptyText).font(.footnote).foregroundStyle(theme.muted).padding(.vertical, 6)
            }
            ForEach(foods) { food in
                FoodRow(food: food, onAdd: { onPick(food) }, onOpen: openAction(food))
            }
            ForEach(warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(theme.muted) }
            Text("Значения на 100 г / 100 мл или на порцию. Сверяйте состав с упаковкой.").font(.caption2).foregroundStyle(theme.muted)
        }
        .task(id: "\(source.rawValue)|\(query)|\(network.isOnline)") { await searchCatalog() }
    }

    private func openAction(_ food: FoodRecord) -> (() -> Void)? {
        guard let onSelectForDetail else { return nil }
        return { onSelectForDetail(food) }
    }

    private var results: [FoodRecord] {
        let _ = store.revision
        switch source {
        case .mine: return FoodNutrition.filter(store.foods().filter { !$0.isRecipe }, query: query)
        case .favorites: return FoodNutrition.filter(store.foods().filter(\.isFavorite), query: query)
        case .recent: return FoodNutrition.filter(store.recentFoods(), query: query)
        case .recipes: return FoodNutrition.filter(store.foods().filter(\.isRecipe), query: query)
        case .catalog: return catalog.map { $0.toFoodRecord() }
        }
    }

    private var emptyText: String {
        switch source {
        case .catalog:
            return query.trimmingCharacters(in: .whitespaces).count < 2 ? "Введите от двух букв для поиска в YAZIO." : "Ничего не найдено."
        case .mine: return "Своих продуктов пока нет. Создайте продукт на экране «Еда»."
        case .favorites: return "Добавьте продукты в избранное в их карточке."
        case .recent: return "Здесь появятся продукты из недавних приёмов пищи."
        case .recipes: return "Создайте своё блюдо на экране «Еда»."
        }
    }

    private func searchCatalog() async {
        guard source == .catalog else { return }
        let text = query
        guard network.isOnline, text.trimmingCharacters(in: .whitespaces).count >= 2 else {
            catalog = []
            warnings = []
            return
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        if Task.isCancelled { return }
        searching = true
        let prefs = store.preferences
        let options = FoodCatalogSearch.Options(yazioEnabled: prefs.yazioEnabled, country: prefs.yazioCountry, locale: prefs.yazioLocale,
                                                usdaKey: prefs.usdaEnabled ? KeychainStore.get(KeychainStore.usdaAccount) : nil)
        let result = await FoodCatalogSearch.search(text, options: options, transport: HTTPClient.transport)
        if Task.isCancelled { return }
        catalog = result.foods
        warnings = result.warnings
        searching = false
    }
}

struct FoodRow: View {
    @Environment(\.theme) private var theme
    let food: FoodRecord
    let onAdd: () -> Void
    var onOpen: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Button { (onOpen ?? onAdd)() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(food.name).font(.subheadline.weight(.semibold)).foregroundStyle(theme.text).lineLimit(2)
                    Text("\(food.brand.isEmpty ? sourceName : food.brand) · на \(food.servingName)")
                        .font(.caption).foregroundStyle(theme.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Text("\(BolusFormat.decimal(food.carbs)) г угл.").font(.caption).foregroundStyle(theme.accent)
            Button(action: onAdd) { Image(systemName: "plus.circle.fill").font(.title3) }
                .buttonStyle(.plain)
                .foregroundStyle(theme.accent)
                .accessibilityLabel("Добавить \(food.name)")
        }
        .padding(.vertical, 6)
    }

    private var sourceName: String {
        switch food.source {
        case "yazio": return "YAZIO"
        case "usda": return "USDA"
        case "recipe": return "Мои блюда"
        case "custom": return "Мой продукт"
        default: return "Недавно в дневнике"
        }
    }
}

/// Editable list of picked foods with live nutrition totals.
struct IngredientEditor: View {
    @Environment(\.theme) private var theme
    @Binding var items: [PickedFood]

    var body: some View {
        ForEach(items) { picked in
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(picked.food.name).font(.subheadline.weight(.semibold)).foregroundStyle(theme.text).lineLimit(1)
                    Text(picked.item.map { "\(BolusFormat.decimal($0.carbs)) г угл. · \(BolusFormat.decimal($0.calories, 0)) ккал" } ?? "Укажите количество")
                        .font(.caption).foregroundStyle(theme.muted)
                }
                Spacer()
                TextField("100", text: amountBinding(picked.id))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.center)
                    .frame(width: 70)
                    .padding(6)
                    .background(theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(picked.food.unitLabel).font(.caption).foregroundStyle(theme.muted)
                Button { items.removeAll { $0.id == picked.id } } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.muted)
                    .accessibilityLabel("Убрать \(picked.food.name)")
            }
            .padding(10)
            .background(theme.background)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func amountBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { items.first { $0.id == id }?.amountText ?? "" },
                set: { value in
                    if let index = items.firstIndex(where: { $0.id == id }) { items[index].amountText = value }
                })
    }
}

struct FoodView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var detail: FoodRecord?
    @State private var showCustom = false
    @State private var showRecipe = false
    @State private var mealDraft: FoodRecord?

    var body: some View {
        Screen {
            PageHeading(title: "Еда, которая вам нравится", subtitle: "Продукты, любимые блюда и понятный подсчёт углеводов.")
            HStack {
                Button { showCustom = true } label: { Label("Продукт", systemImage: "plus") }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                Button { showRecipe = true } label: { Label("Моё блюдо", systemImage: "fork.knife") }
                    .buttonStyle(PrimaryButtonStyle(fullWidth: true))
            }
            Card {
                FoodPicker(onPick: { mealDraft = $0 }, onSelectForDetail: { detail = $0 })
            }
            Notice(text: "Свои продукты, избранное, недавние и рецепты работают без интернета. Поиск YAZIO/USDA выполняется напрямую с iPhone, когда есть сеть.",
                   systemImage: "wifi.slash")
        }
        .navigationTitle("Еда")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $detail) { food in
            NavigationStack { FoodDetailView(food: food, onAddToMeal: { detail = nil; mealDraft = food }) }.environment(\.theme, theme)
        }
        .sheet(isPresented: $showCustom) { NavigationStack { CustomFoodForm() }.environment(\.theme, theme) }
        .sheet(isPresented: $showRecipe) { NavigationStack { RecipeForm() }.environment(\.theme, theme) }
        .sheet(item: $mealDraft) { food in
            NavigationStack { AddEntryView(initialSection: .meal, initialFood: food) }.environment(\.theme, theme)
        }
    }
}

struct FoodDetailView: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    let food: FoodRecord
    var onAddToMeal: (() -> Void)? = nil
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        let _ = store.revision
        let favorite = store.isFavorite(food)
        let saved = store.foods().contains { $0.id == food.id || $0.catalogKey == food.catalogKey }
        Screen {
            Card {
                Text(food.name).font(.title3.weight(.semibold)).foregroundStyle(theme.text)
                Text("На \(food.servingName) · \(source)").font(.footnote).foregroundStyle(theme.muted)
                DataRow(label: "Углеводы", value: "\(BolusFormat.decimal(food.carbs)) г")
                DataRow(label: "Белки", value: "\(BolusFormat.decimal(food.protein)) г")
                DataRow(label: "Жиры", value: "\(BolusFormat.decimal(food.fat)) г")
                DataRow(label: "Энергия", value: "\(BolusFormat.decimal(food.calories, 0)) ккал")
                DataRow(label: "Клетчатка", value: food.fiber.map { "\(BolusFormat.decimal($0)) г" } ?? "Не указано")
                DataRow(label: "Сахар", value: food.sugar.map { "\(BolusFormat.decimal($0)) г" } ?? "Не указано")
                if let recipe = food.recipe {
                    Text("Рецепт: \(recipe.ingredients.count) ингр., готовый вес \(BolusFormat.number(recipe.cookedWeight)) г, порций: \(recipe.servings)")
                        .font(.caption).foregroundStyle(theme.muted)
                }
            }
            if let message { Notice(text: message, style: .success) }
            if let error { Notice(text: error, style: .error) }
            Button {
                run { try store.toggleFavorite(food) }
            } label: { Label(favorite ? "Убрать из избранного" : "В избранное", systemImage: favorite ? "heart.slash" : "heart") }
                .buttonStyle(SecondaryButtonStyle(fullWidth: true))
            if !saved {
                Button {
                    run {
                        try store.saveFood(food)
                        message = "Продукт сохранён на устройстве и доступен офлайн"
                    }
                } label: { Label("Сохранить в мои продукты", systemImage: "square.and.arrow.down") }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
            }
            if let onAddToMeal {
                Button(action: onAddToMeal) { Label("Добавить приём пищи", systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle(fullWidth: true))
            }
            if saved && (food.source == "custom" || food.source == "recipe") {
                Button(role: .destructive) {
                    run {
                        try store.deleteFood(id: food.id)
                        dismiss()
                    }
                } label: { Label("Удалить продукт", systemImage: "trash") }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: true))
                Text("Старые записи еды не изменятся: в них хранится снимок пищевой ценности.").font(.caption).foregroundStyle(theme.muted)
            }
        }
        .navigationTitle("Продукт")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
    }

    private var source: String {
        switch food.source {
        case "yazio": return "YAZIO"
        case "usda": return "USDA"
        case "recipe": return "Моё блюдо"
        case "custom": return "Мой продукт"
        default: return "Из дневника"
        }
    }

    private func run(_ action: () throws -> Void) {
        do {
            error = nil
            try action()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct CustomFoodForm: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var brand = ""
    @State private var liquid = false
    @State private var servingName = ""
    @State private var weight = "100"
    @State private var carbs = ""
    @State private var protein = ""
    @State private var fat = ""
    @State private var calories = ""
    @State private var fiber = ""
    @State private var sugar = ""
    @State private var error: String?

    var body: some View {
        Screen {
            Card {
                LabeledField(title: "Название") { TextField("Например, сырник", text: $name) }
                LabeledField(title: "Бренд · необязательно") { TextField("", text: $brand) }
                Toggle("Жидкость (мл)", isOn: $liquid)
                LabeledField(title: "Порция · необязательно", hint: "Например, «1 шт». По умолчанию — вес порции.") {
                    TextField("100 \(liquid ? "мл" : "г")", text: $servingName)
                }
                NumberField(title: "Вес порции", text: $weight, unit: liquid ? "мл" : "г")
                Text("Пищевая ценность на указанную порцию").font(.caption).foregroundStyle(theme.muted)
                NumberField(title: "Углеводы", text: $carbs, unit: "г")
                NumberField(title: "Белки", text: $protein, unit: "г", placeholder: "0")
                NumberField(title: "Жиры", text: $fat, unit: "г", placeholder: "0")
                NumberField(title: "Калории", text: $calories, unit: "ккал", placeholder: "0")
                NumberField(title: "Клетчатка · необязательно", text: $fiber, unit: "г", placeholder: "не указано")
                NumberField(title: "Сахар · необязательно", text: $sugar, unit: "г", placeholder: "не указано")
            }
            if let error { Notice(text: error, style: .error) }
            Button("Создать продукт", action: save).buttonStyle(PrimaryButtonStyle(fullWidth: true))
            Text("Продукт хранится только на этом iPhone и работает без интернета.").font(.caption).foregroundStyle(theme.muted)
        }
        .navigationTitle("Свой продукт")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
    }

    private func save() {
        do {
            guard let carbsValue = BolusFormat.parse(carbs) else { throw BolusError.validation("Укажите углеводы") }
            let food = try FoodNutrition.customFood(
                name: name, brand: brand, baseUnit: liquid ? "ml" : "g", servingName: servingName.isEmpty ? nil : servingName,
                servingWeight: BolusFormat.parse(weight) ?? 100, carbs: carbsValue, protein: BolusFormat.parse(protein) ?? 0,
                fat: BolusFormat.parse(fat) ?? 0, calories: BolusFormat.parse(calories) ?? 0,
                fiber: BolusFormat.parse(fiber), sugar: BolusFormat.parse(sugar))
            try store.saveFood(food)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct RecipeForm: View {
    @Environment(DiaryStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var items: [PickedFood] = []
    @State private var weight = ""
    @State private var servings = "1"
    @State private var error: String?

    var body: some View {
        let ingredients = items.compactMap(\.item)
        let carbs = ingredients.reduce(0.0) { $0 + $1.carbs }
        Screen {
            Card {
                LabeledField(title: "Название блюда") { TextField("Например, сырники", text: $name) }
                FoodPicker(onPick: { items.append(PickedFood(food: $0)) })
                IngredientEditor(items: $items)
                NumberField(title: "Вес готового блюда", text: $weight, unit: "г")
                NumberField(title: "Число порций", text: $servings)
                if let cooked = BolusFormat.parse(weight), cooked > 0 {
                    Notice(text: "Углеводы: \(BolusFormat.decimal(carbs / cooked * 100)) г на 100 г · \(BolusFormat.decimal(carbs / Double(max(Int(BolusFormat.parse(servings) ?? 1), 1)))) г на порцию")
                }
            }
            if let error { Notice(text: error, style: .error) }
            Button("Сохранить блюдо", action: save).buttonStyle(PrimaryButtonStyle(fullWidth: true))
        }
        .navigationTitle("Моё блюдо")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
    }

    private func save() {
        do {
            let ingredients = items.compactMap(\.item)
            guard ingredients.count == items.count else { throw BolusError.validation("Укажите количество каждого ингредиента") }
            let recipe = try FoodNutrition.recipe(name: name, ingredients: ingredients, cookedWeight: BolusFormat.parse(weight) ?? 0,
                                                  servings: Int(BolusFormat.parse(servings) ?? 0))
            try store.saveFood(recipe)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
