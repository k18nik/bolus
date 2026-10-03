import Foundation

/// Product found in an external catalog. Nutrients are per 100 g or 100 ml (`baseUnit`).
public struct CatalogFood: Equatable, Identifiable, Sendable {
    public var externalID: String
    public var name: String
    public var brand: String
    public var provider: String
    public var baseUnit: String
    public var servingWeight: Double
    public var servingName: String
    public var carbs: Double
    public var protein: Double
    public var fat: Double
    public var calories: Double
    public var fiber: Double?
    public var sugar: Double?
    public var isVerified: Bool

    public var id: String { provider + ":" + externalID }

    /// Saving a catalog product creates an independent local copy.
    public func toFoodRecord(now: Date = Date()) -> FoodRecord {
        FoodRecord(name: name, brand: brand, source: provider, externalID: externalID, baseUnit: baseUnit, servingName: servingName,
                   servingWeight: servingWeight, carbs: carbs, protein: protein, fat: fat, calories: calories, fiber: fiber,
                   sugar: sugar, createdAt: now)
    }
}

public enum FoodCatalogError: Error, Equatable {
    case message(String)
}

/// YAZIO v15 public product search (port of `backend/app/food/yazio.py`).
/// Only the public catalog is used: no login, no diary access, no writes.
public enum YazioCatalog {
    public static let searchEndpoint = URL(string: "https://yzapi.yazio.com/v15/products/search")!

    public static func request(query: String, country: String = "RU", locale: String = "ru_RU", sex: String = "male") -> HTTPRequestSpec {
        var components = URLComponents(url: searchEndpoint, resolvingAgainstBaseURL: false)!
        // `sex` is a fixed catalog compatibility parameter, never the user's data.
        components.queryItems = [
            URLQueryItem(name: "query", value: query), URLQueryItem(name: "countries", value: country),
            URLQueryItem(name: "locales", value: locale), URLQueryItem(name: "sex", value: sex),
        ]
        return HTTPRequestSpec(url: components.url!, method: "GET", headers: ["Accept": "application/json"], timeout: 12)
    }

    /// `Decimal(str(value)) * 100`, finite and within `0...maximum`, `round(…, 4)`.
    static func nutrient(_ value: JSONValue?, maximum: Double) throws -> Double {
        let decimal: PyDecimal?
        switch value {
        case .number(let number)?: decimal = PyDecimal(number)
        case .string(let text)?: decimal = PyDecimal(string: text)
        default: decimal = nil
        }
        guard let parsed = decimal else { throw FoodCatalogError.message("Missing or invalid nutrient") }
        let scaled = parsed * PyDecimal(coefficient: BigUInt(100), exponent: 0)
        let max = PyDecimal(maximum)!
        guard !(scaled < .zero), !(scaled > max) else { throw FoodCatalogError.message("Invalid nutrient range") }
        return scaled.rounded(places: 4).doubleValue
    }

    public static func normalize(_ product: JSONValue) throws -> CatalogFood {
        guard case .object(let raw) = product else { throw FoodCatalogError.message("Invalid product") }
        guard let unit = raw["base_unit"]?.stringValue, ["g", "ml"].contains(unit) else { throw FoodCatalogError.message("Unknown nutrition basis") }
        guard let identity = raw["product_id"]?.stringValue, (1...100).contains(identity.count) else { throw FoodCatalogError.message("Invalid identity") }
        guard let name = raw["name"]?.stringValue, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 150 else {
            throw FoodCatalogError.message("Invalid name")
        }
        let brandValue = raw["producer"] ?? .null
        let brand: String
        switch brandValue {
        case .null: brand = ""
        case .string(let text): brand = text
        default: throw FoodCatalogError.message("Invalid brand")
        }
        guard brand.count <= 100 else { throw FoodCatalogError.message("Invalid brand") }
        guard case .object(let nutrients)? = raw["nutrients"] else { throw FoodCatalogError.message("Missing nutrients") }
        // Missing fiber/sugar remain unknown; zero carbohydrate is accepted only explicitly.
        func optional(_ key: String) throws -> Double? {
            guard let value = nutrients[key], value != .null else { return nil }
            return try nutrient(value, maximum: 100)
        }
        let serving = unit == "ml" ? "100 мл" : "100 г"
        return CatalogFood(
            externalID: identity, name: name.trimmingCharacters(in: .whitespacesAndNewlines), brand: brand, provider: "yazio",
            baseUnit: unit, servingWeight: 100, servingName: serving,
            carbs: try nutrient(nutrients["nutrient.carb"], maximum: 100), protein: try nutrient(nutrients["nutrient.protein"], maximum: 100),
            fat: try nutrient(nutrients["nutrient.fat"], maximum: 100), calories: try nutrient(nutrients["energy.energy"], maximum: 1000),
            fiber: try optional("nutrient.fiber"), sugar: try optional("nutrient.sugar"), isVerified: raw["is_verified"] == .bool(true))
    }

    public static let skippedWarning = "Часть продуктов YAZIO пропущена: состав или единицы измерения не указаны корректно."

    public static func message(forStatus status: Int) -> String? {
        switch status {
        case 200: return nil
        case 401, 403: return "YAZIO ограничил публичный поиск. Сейчас доступны ваши продукты и ручной ввод."
        case 429: return "YAZIO ограничил частоту поиска. Повторите немного позже."
        default: return "YAZIO временно не выполнил поиск."
        }
    }

    public static func parse(_ response: HTTPResponseData) throws -> (foods: [CatalogFood], warnings: [String]) {
        if let message = message(forStatus: response.status) { throw FoodCatalogError.message(message) }
        guard let body = try? BolusJSON.decoder.decode(JSONValue.self, from: response.body) else {
            throw FoodCatalogError.message("YAZIO вернул некорректный ответ.")
        }
        guard case .array(let products) = body else {
            throw FoodCatalogError.message("Формат ответа YAZIO изменился. Сейчас доступны ваши продукты.")
        }
        var result: [CatalogFood] = []
        var seen = Set<String>()
        var skipped = 0
        for raw in products.prefix(100) {
            guard let food = try? normalize(raw) else { skipped += 1; continue }
            if !seen.contains(food.externalID) {
                result.append(food)
                seen.insert(food.externalID)
            }
            if result.count >= 30 { break }
        }
        return (result, skipped > 0 ? [skippedWarning] : [])
    }
}

/// Optional USDA FoodData Central fallback (requires the user's API key in the Keychain).
public enum USDACatalog {
    public static let searchEndpoint = URL(string: "https://api.nal.usda.gov/fdc/v1/foods/search")!

    public static func request(query: String, apiKey: String) -> HTTPRequestSpec {
        var components = URLComponents(url: searchEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey), URLQueryItem(name: "query", value: query),
                                 URLQueryItem(name: "pageSize", value: "20")]
        return HTTPRequestSpec(url: components.url!, method: "GET", headers: ["Accept": "application/json"], timeout: 8)
    }

    /// Foods without a carbohydrate value are skipped instead of assuming 0 g.
    public static func parse(_ response: HTTPResponseData) throws -> (foods: [CatalogFood], skipped: Int) {
        guard response.status == 200, let body = try? BolusJSON.decoder.decode(JSONValue.self, from: response.body) else {
            throw FoodCatalogError.message("Резервный каталог USDA временно недоступен.")
        }
        var result: [CatalogFood] = []
        var skipped = 0
        for food in body["foods"]?.arrayValue ?? [] {
            var nutrients: [Int: Double] = [:]
            for nutrient in food["foodNutrients"]?.arrayValue ?? [] {
                if let id = nutrient.double("nutrientId").flatMap({ Int(exactly: $0) }), let value = nutrient.double("value"), value.isFinite, value >= 0 {
                    nutrients[id] = value
                }
            }
            guard let carbs = nutrients[1005], let name = food.string("description"),
                  let fdcID = (food.double("fdcId") ?? food.string("fdcId").flatMap(Double.init)).flatMap({ Int(exactly: $0) }) else {
                skipped += 1
                continue
            }
            result.append(CatalogFood(externalID: String(fdcID), name: String(name.prefix(150)),
                                      brand: String((food.string("brandName") ?? "").prefix(100)), provider: "usda", baseUnit: "g",
                                      servingWeight: 100, servingName: "100 г", carbs: carbs, protein: nutrients[1003] ?? 0,
                                      fat: nutrients[1004] ?? 0, calories: nutrients[1008] ?? 0, fiber: nutrients[1079],
                                      sugar: nutrients[2000], isVerified: false))
        }
        return (result, skipped)
    }
}

/// External search orchestration (port of `search_foods`): YAZIO first, USDA as an
/// explicit fallback. Failures are reported as warnings; local foods stay available.
public enum FoodCatalogSearch {
    public struct Options: Sendable {
        public var yazioEnabled: Bool
        public var country: String
        public var locale: String
        public var usdaKey: String?

        public init(yazioEnabled: Bool = true, country: String = "RU", locale: String = "ru_RU", usdaKey: String? = nil) {
            self.yazioEnabled = yazioEnabled
            self.country = country
            self.locale = locale
            self.usdaKey = usdaKey
        }
    }

    public static let offlineMessage = "Внешний поиск (YAZIO/USDA) требует интернет. Доступны ваши продукты, избранное, недавние и рецепты."
    public static let notFoundMessage = "Во внешней базе ничего не найдено. Попробуйте другое название или создайте свой продукт."

    public static func search(_ rawQuery: String, options: Options, transport: HTTPTransport) async -> (foods: [CatalogFood], warnings: [String]) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return ([], []) }
        var warnings: [String] = []
        if options.yazioEnabled {
            do {
                let response = try await transport(YazioCatalog.request(query: query, country: options.country, locale: options.locale))
                let (foods, extra) = try YazioCatalog.parse(response)
                warnings += extra
                if !foods.isEmpty { return (foods, warnings) }
            } catch FoodCatalogError.message(let message) {
                warnings.append(message)
            } catch {
                warnings.append("YAZIO временно не отвечает. Повторите поиск позже.")
            }
        }
        if let key = options.usdaKey, !key.isEmpty {
            do {
                let (foods, _) = try USDACatalog.parse(try await transport(USDACatalog.request(query: query, apiKey: key)))
                if !foods.isEmpty { return (foods, warnings + ["Показаны результаты резервного каталога USDA."]) }
            } catch {
                warnings.append("Резервный каталог USDA временно недоступен.")
            }
        }
        return ([], warnings.isEmpty ? [notFoundMessage] : warnings)
    }
}
