import Foundation

/// Full local backup. `schemaVersion` identifies the format:
/// - 1 — JSON backup of the former server (`schema_version: "1.0"`), migrated on import;
/// - 2 — local-first iPhone database (this structure).
/// Records keep the backend field names so the same data can move between both worlds.
public struct BackupDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2
    public static let formatIdentifier = "bolus-local-backup"

    public struct AppInfo: Codable, Equatable, Sendable {
        public var name: String
        public var version: String
        public var algorithmVersion: String
        public var iobModel: String

        public init(name: String = "Bolus", version: String, algorithmVersion: String = BolusEngine.algorithmVersion,
                    iobModel: String = IOBEngine.modelVersion) {
            self.name = name
            self.version = version
            self.algorithmVersion = algorithmVersion
            self.iobModel = iobModel
        }
    }

    public var schemaVersion: Int
    public var format: String
    public var exportedAt: Date
    public var app: AppInfo
    public var preferences: AppPreferences?
    public var therapyProfiles: [TherapyProfileRecord]
    public var entries: [DiaryRecord]
    public var bolusCalculations: [BolusCalculationRecord]
    public var foods: [FoodRecord]
    public var cycles: [CycleRecord]
    public var aiInsights: [AIInsightRecord]
    public var auditEvents: [AuditRecord]
    /// Notes about conversions applied during migration from older formats.
    public var migrationNotes: [String]

    public init(exportedAt: Date, appVersion: String, preferences: AppPreferences?, therapyProfiles: [TherapyProfileRecord],
                entries: [DiaryRecord], bolusCalculations: [BolusCalculationRecord], foods: [FoodRecord], cycles: [CycleRecord],
                aiInsights: [AIInsightRecord], auditEvents: [AuditRecord], migrationNotes: [String] = []) {
        schemaVersion = Self.currentSchemaVersion
        format = Self.formatIdentifier
        self.exportedAt = exportedAt
        app = AppInfo(version: appVersion)
        self.preferences = preferences
        self.therapyProfiles = therapyProfiles
        self.entries = entries
        self.bolusCalculations = bolusCalculations
        self.foods = foods
        self.cycles = cycles
        self.aiInsights = aiInsights
        self.auditEvents = auditEvents
        self.migrationNotes = migrationNotes
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, format, exportedAt, app, preferences, therapyProfiles, entries, bolusCalculations, foods, cycles
        case aiInsights, auditEvents, migrationNotes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        format = try c.value(.format, default: Self.formatIdentifier)
        exportedAt = try c.decode(ISODateString.self, forKey: .exportedAt).date
        app = try c.value(.app, default: AppInfo(version: "?"))
        preferences = try c.decodeIfPresent(AppPreferences.self, forKey: .preferences)
        therapyProfiles = try c.value(.therapyProfiles, default: [])
        entries = try c.value(.entries, default: [])
        bolusCalculations = try c.value(.bolusCalculations, default: [])
        foods = try c.value(.foods, default: [])
        cycles = try c.value(.cycles, default: [])
        aiInsights = try c.value(.aiInsights, default: [])
        auditEvents = try c.value(.auditEvents, default: [])
        migrationNotes = try c.value(.migrationNotes, default: [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(format, forKey: .format)
        try c.encode(ISODateString(exportedAt), forKey: .exportedAt)
        try c.encode(app, forKey: .app)
        try c.encodeIfPresent(preferences, forKey: .preferences)
        try c.encode(therapyProfiles, forKey: .therapyProfiles)
        try c.encode(entries, forKey: .entries)
        try c.encode(bolusCalculations, forKey: .bolusCalculations)
        try c.encode(foods, forKey: .foods)
        try c.encode(cycles, forKey: .cycles)
        try c.encode(aiInsights, forKey: .aiInsights)
        try c.encode(auditEvents, forKey: .auditEvents)
        try c.encode(migrationNotes, forKey: .migrationNotes)
    }

    public func encoded() throws -> Data { try BolusJSON.prettyEncoder.encode(self) }

    public var recordCount: Int {
        therapyProfiles.count + entries.count + bolusCalculations.count + foods.count + cycles.count + aiInsights.count + auditEvents.count
    }
}

/// Reads any supported backup version and migrates it step by step to the current one.
public enum BackupMigrator {
    public static func decode(_ data: Data) throws -> BackupDocument {
        guard let root = try? BolusJSON.decoder.decode(JSONValue.self, from: data), case .object(let object) = root else {
            throw BolusError.validation("Файл не похож на резервную копию Bolus (ожидается JSON).")
        }
        var version: Int
        if let number = object["schemaVersion"]?.doubleValue {
            version = Int(number)
        } else if object["schema_version"]?.stringValue == "1.0" {
            version = 1
        } else {
            throw BolusError.validation("Неизвестный формат резервной копии: нет schemaVersion.")
        }
        guard version <= BackupDocument.currentSchemaVersion else {
            throw BolusError.validation("Копия создана более новой версией Bolus (schemaVersion \(version)). Обновите приложение.")
        }
        var current = root
        // Migration chain: each step converts version N to N+1.
        while version < BackupDocument.currentSchemaVersion {
            switch version {
            case 1: current = try migrateServerV1(current)
            default: throw BolusError.validation("Нет миграции для schemaVersion \(version).")
            }
            version += 1
        }
        do {
            return try current.decode(BackupDocument.self)
        } catch {
            throw BolusError.validation("Резервная копия повреждена или неполна: \(error.localizedDescription)")
        }
    }

    static func uuid(_ value: JSONValue?) -> UUID? { value?.stringValue.flatMap(UUID.init(uuidString:)) }

    /// v1 (server JSON export) → v2 (local document).
    static func migrateServerV1(_ root: JSONValue) throws -> JSONValue {
        let datasets = root["datasets"] ?? .object([:])
        func rows(_ name: String) -> [JSONValue] { datasets[name]?.arrayValue ?? [] }
        var notes = ["Импорт из серверной резервной копии (schema_version 1.0)."]
        let exportedAt = root.string("exported_at").flatMap(ISODate.parse) ?? Date()

        var preferences: JSONValue = .null
        if case .object(let user)? = root["user"] {
            var prefs: [String: JSONValue] = ["onboarding_completed": .bool(true)]
            for (from, to) in [("name", "name"), ("timezone", "timezone"), ("glucose_unit", "glucose_unit"), ("theme_id", "theme_id"), ("mascot_id", "mascot_id")] {
                if let value = user[from], value != .null { prefs[to] = value }
            }
            preferences = .object(prefs)
        }

        var calculationEntries: [String: String] = [:]
        var entries: [JSONValue] = []
        for row in root["entries"]?.arrayValue ?? [] {
            guard let id = row.string("id"), let kind = row.string("kind"), EntryKind(rawValue: kind) != nil,
                  let occurred = row.string("occurred_at"), let data = row["data"] else { continue }
            let updated = row.string("updated_at") ?? occurred
            var dedupe: JSONValue = .null
            if data.string("source_kind") == "healthkit" {
                if kind == EntryKind.activity.rawValue, let external = data.string("external_id") {
                    dedupe = .string(HealthImportPlanner.workoutKey(external))
                } else if kind == EntryKind.activitySummary.rawValue, let day = data.string("local_date") {
                    dedupe = .string(HealthImportPlanner.dayKey(day))
                }
            }
            if let calculation = data.string("related_bolus_calculation_id") {
                dedupe = .string("bolus:" + calculation.lowercased())
                calculationEntries[calculation.lowercased()] = id.lowercased()
            }
            let identity = UUID(uuidString: id)?.uuidString.lowercased() ?? UUID().uuidString.lowercased()
            entries.append(.object([
                "id": .string(identity), "client_id": .string(identity), "kind": .string(kind), "occurred_at": .string(occurred),
                "data": data, "created_at": .string(updated), "updated_at": .string(updated),
                "version": row["version"] ?? .number(1), "dedupe_key": dedupe,
            ]))
        }

        var profiles: [JSONValue] = []
        let rawProfiles = rows("Therapy Profiles")
        let activeVersion = rawProfiles.filter { $0["valid_to"] == nil || $0["valid_to"] == .null }.compactMap { $0.double("version") }.max()
        for row in rawProfiles {
            guard let id = row.string("id"), let data = row["data"], let version = row.double("version") else { continue }
            let validTo = row["valid_to"] ?? .null
            profiles.append(.object([
                "id": .string(id.lowercased()), "version": .number(version), "valid_from": row["valid_from"] ?? .string(ISODate.format(exportedAt)),
                "valid_to": validTo, "status": .string(validTo == .null && version == activeVersion ? "active" : "archived"),
                "source": row["source"] ?? .string("manual"), "data": data,
            ]))
        }

        var calculations: [JSONValue] = []
        for row in rows("Bolus Calculations") {
            guard let id = row.string("id") else { continue }
            var object = row.objectValue ?? [:]
            object["id"] = .string(id.lowercased())
            if let entry = calculationEntries[id.lowercased()] { object["confirmed_entry_id"] = .string(entry) }
            calculations.append(.object(object))
        }

        var foods: [JSONValue] = []
        var foodKeys: [String: Int] = [:]
        for row in rows("Foods") {
            guard let id = row.string("id"), case .object(var data)? = row["data"] else { continue }
            data["id"] = .string(id.lowercased())
            data["name"] = row["name"] ?? data["name"] ?? .string("Продукт")
            let isRecipe = row["is_recipe"] == .bool(true)
            data["is_recipe"] = .bool(isRecipe)
            data["source"] = .string(isRecipe ? "recipe" : "custom")
            if isRecipe, case .object(var recipe)? = data["recipe"] {
                recipe["total"] = data["total"] ?? .object([:])
                recipe["per_serving"] = data["per_serving"] ?? .object([:])
                recipe.removeValue(forKey: "name")
                data["recipe"] = .object(recipe)
            }
            data.removeValue(forKey: "total")
            data.removeValue(forKey: "per_serving")
            data["created_at"] = .string(ISODate.format(exportedAt))
            foodKeys["custom:" + id.lowercased()] = foods.count
            foods.append(.object(data))
        }
        for row in rows("Food Favorites") {
            guard case .object(var data)? = row["data"] else { continue }
            let provider = data["provider"]?.stringValue ?? "custom"
            let external = data["external_id"]?.stringValue ?? ""
            let key = provider + ":" + external.lowercased()
            if let index = foodKeys[key], case .object(var existing) = foods[index] {
                existing["is_favorite"] = .bool(true)
                foods[index] = .object(existing)
                continue
            }
            data["id"] = .string((uuid(row["id"]) ?? UUID()).uuidString.lowercased())
            data["source"] = .string(provider)
            data["external_id"] = .string(external)
            data.removeValue(forKey: "provider")
            data["is_favorite"] = .bool(true)
            data["created_at"] = .string(ISODate.format(exportedAt))
            foods.append(.object(data))
        }

        let cycles: [JSONValue] = rows("Cycle").compactMap { row in
            guard let id = row.string("id"), let start = row["start_date"] else { return nil }
            return .object(["id": .string(id.lowercased()), "start_date": start, "end_date": row["end_date"] ?? .null,
                            "cycle_length": row["cycle_length"] ?? .number(28), "actual_ovulation_date": row["actual_ovulation_date"] ?? .null])
        }
        let insights: [JSONValue] = rows("AI Insights").compactMap { row in
            guard var object = row.objectValue, let id = row.string("id") else { return nil }
            object["id"] = .string(id.lowercased())
            if let calculation = row.string("calculation_id") { object["calculation_id"] = .string(calculation.lowercased()) }
            return .object(object)
        }
        let audit: [JSONValue] = rows("Audit").map { row in
            .object(["id": .string(UUID().uuidString.lowercased()), "timestamp": row["timestamp"] ?? .string(ISODate.format(exportedAt)),
                     "action": row["action"] ?? .string("unknown"), "entity_type": row["entity_type"] ?? .string(""),
                     "entity_id": row["entity_id"] ?? .string(""),
                     "details": .object(["old_value": row["old_value"] ?? .null, "new_value": row["new_value"] ?? .null, "migrated_from": .string("server")])])
        }
        if root["entries"]?.arrayValue?.count != entries.count { notes.append("Часть записей неизвестного типа пропущена.") }
        notes.append("API-ключи и пароли в копии отсутствуют; ключ AI нужно ввести на устройстве заново.")
        return .object([
            "schemaVersion": .number(2), "format": .string(BackupDocument.formatIdentifier),
            "exportedAt": .string(ISODate.format(exportedAt)),
            "app": .object(["name": .string("Bolus server"), "version": .string("1.0"), "algorithmVersion": .string(BolusEngine.algorithmVersion),
                            "iobModel": .string(IOBEngine.modelVersion)]),
            "preferences": preferences, "therapyProfiles": .array(profiles), "entries": .array(entries),
            "bolusCalculations": .array(calculations), "foods": .array(foods), "cycles": .array(cycles),
            "aiInsights": .array(insights), "auditEvents": .array(audit), "migrationNotes": .array(notes.map(JSONValue.string)),
        ])
    }
}

/// Merge plan: backups are added, never silently overwrite local data.
public struct BackupImportPlan: Equatable, Sendable {
    public var document: BackupDocument
    public var newProfiles: [TherapyProfileRecord] = []
    public var newEntries: [DiaryRecord] = []
    public var newCalculations: [BolusCalculationRecord] = []
    public var newFoods: [FoodRecord] = []
    public var newCycles: [CycleRecord] = []
    public var newInsights: [AIInsightRecord] = []
    public var newAudit: [AuditRecord] = []
    /// Same id and same content: nothing to do.
    public var identical = 0
    /// Same identity (id, HealthKit UUID, confirmation) with different content: local version kept.
    public var conflicts: [String] = []
    /// Imported active profiles that became history because the device already has an active profile.
    public var profilesArchivedOnImport = 0
    /// Preferences are applied only to an empty diary.
    public var applyPreferences = false

    public var newCount: Int {
        newProfiles.count + newEntries.count + newCalculations.count + newFoods.count + newCycles.count + newInsights.count + newAudit.count
    }

    public var summary: String {
        var lines = ["Будет добавлено: \(newCount)", "Уже есть на устройстве: \(identical)"]
        if !conflicts.isEmpty { lines.append("Конфликтов: \(conflicts.count) — сохранены версии с устройства, копия их не заменит") }
        if profilesArchivedOnImport > 0 { lines.append("Профилей из копии добавлено в историю: \(profilesArchivedOnImport); активным остаётся текущий профиль") }
        lines.append(applyPreferences ? "Настройки оформления и единиц будут восстановлены" : "Текущие настройки устройства сохраняются")
        return lines.joined(separator: "\n")
    }
}

public struct ExistingData: Sendable {
    public var profiles: [TherapyProfileRecord]
    public var entries: [DiaryRecord]
    public var calculations: [BolusCalculationRecord]
    public var foods: [FoodRecord]
    public var cycles: [CycleRecord]
    public var insights: [AIInsightRecord]
    public var audit: [AuditRecord]

    public init(profiles: [TherapyProfileRecord] = [], entries: [DiaryRecord] = [], calculations: [BolusCalculationRecord] = [],
                foods: [FoodRecord] = [], cycles: [CycleRecord] = [], insights: [AIInsightRecord] = [], audit: [AuditRecord] = []) {
        self.profiles = profiles
        self.entries = entries
        self.calculations = calculations
        self.foods = foods
        self.cycles = cycles
        self.insights = insights
        self.audit = audit
    }

    public var isEmpty: Bool { profiles.isEmpty && entries.isEmpty && calculations.isEmpty && foods.isEmpty && cycles.isEmpty }
}

public enum BackupImportPlanner {
    /// Records are compared in their serialized form (dates at microsecond precision),
    /// so a backup re-imported on the same device is recognised as identical.
    static func same<T: Encodable>(_ a: T, _ b: T) -> Bool {
        let encoder = BolusJSON.encoder
        return (try? encoder.encode(a)) == (try? encoder.encode(b))
    }

    public static func plan(_ document: BackupDocument, existing: ExistingData) -> BackupImportPlan {
        var plan = BackupImportPlan(document: document)
        plan.applyPreferences = existing.isEmpty && document.preferences != nil

        func merge<T: Encodable & Identifiable>(_ incoming: [T], _ local: [T], label: String) -> [T] where T.ID == UUID {
            let byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var added: [T] = []
            for item in incoming {
                if let current = byID[item.id] {
                    if same(current, item) { plan.identical += 1 } else { plan.conflicts.append("\(label) \(item.id.uuidString.lowercased())") }
                } else {
                    added.append(item)
                }
            }
            return added
        }

        // Entries: identity by id, client id and external dedupe key (HealthKit UUID, confirmation).
        let localByID = Dictionary(existing.entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let localClientIDs = Set(existing.entries.map(\.clientID))
        let localKeys = Set(existing.entries.compactMap(\.dedupeKey))
        var seenKeys = Set<String>()
        for entry in document.entries {
            if let current = localByID[entry.id] {
                if same(current, entry) { plan.identical += 1 } else { plan.conflicts.append("запись \(entry.id.uuidString.lowercased())") }
                continue
            }
            if localClientIDs.contains(entry.clientID) {
                plan.conflicts.append("запись \(entry.id.uuidString.lowercased())")
                continue
            }
            if let key = entry.dedupeKey, localKeys.contains(key) || seenKeys.contains(key) {
                plan.conflicts.append("запись \(key)")
                continue
            }
            if let key = entry.dedupeKey { seenKeys.insert(key) }
            plan.newEntries.append(entry)
        }

        let hasActiveProfile = existing.profiles.contains(where: \.isActive)
        let newProfiles = merge(document.therapyProfiles, existing.profiles, label: "профиль")
        var archivedOnImport = 0
        plan.newProfiles = newProfiles.map { profile in
            guard hasActiveProfile, profile.isActive else { return profile }
            var archived = profile
            archived.status = "archived"
            archived.validTo = archived.validTo ?? document.exportedAt
            archivedOnImport += 1
            return archived
        }
        plan.profilesArchivedOnImport = archivedOnImport
        // A calculation confirmed on the device keeps its own confirmation (conflict, not overwrite).
        plan.newCalculations = merge(document.bolusCalculations, existing.calculations, label: "расчёт")
        plan.newFoods = merge(document.foods, existing.foods, label: "продукт")
        plan.newCycles = merge(document.cycles, existing.cycles, label: "цикл")
        plan.newInsights = merge(document.aiInsights, existing.insights, label: "AI-анализ")
        plan.newAudit = merge(document.auditEvents, existing.audit, label: "событие аудита")
        return plan
    }
}
