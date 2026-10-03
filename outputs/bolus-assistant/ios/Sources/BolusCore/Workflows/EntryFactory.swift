import Foundation

/// Validated creation of diary records: port of the Pydantic schemas in
/// `backend/app/schemas/domain.py` and of the create endpoints in `api/routes.py`.
/// Pure: the caller persists the returned records.
public struct EntryFactory {
    public var now: Date
    public var timeZone: TimeZone

    public init(now: Date = Date(), timeZone: TimeZone) {
        self.now = now
        self.timeZone = timeZone
    }

    /// Entries may be up to 5 minutes in the future (clock skew), not more.
    public static let futureTolerance: TimeInterval = 5 * 60

    static let glucoseSources: Set<String> = ["manual", "CGM", "glucometer", "import"]
    static let trends: Set<String> = ["rapid_down", "down", "slight_down", "stable", "slight_up", "up", "rapid_up", "unknown"]
    static let intensities: Set<String> = ["low", "moderate", "high"]

    func checkTime(_ date: Date) throws {
        if date > now.addingTimeInterval(Self.futureTolerance) { throw BolusError.validation("Время записи находится в будущем") }
    }

    func checkNote(_ note: String) throws {
        if note.count > 2000 { throw BolusError.validation("Заметка длиннее 2000 символов") }
    }

    func record(_ kind: EntryKind, _ occurredAt: Date, _ payload: some Encodable, clientID: UUID = UUID(), dedupeKey: String? = nil) throws -> DiaryRecord {
        DiaryRecord(clientID: clientID, kind: kind, occurredAt: occurredAt, data: try JSONValue.encode(payload),
                    createdAt: now, dedupeKey: dedupeKey)
    }

    // MARK: Glucose

    public func glucose(value: Double, unit: GlucoseUnit, measuredAt: Date, source: String = "manual",
                        trend: String = "unknown", note: String = "", clientID: UUID = UUID()) throws -> DiaryRecord {
        guard value.isFinite, value > 0, value <= 1000 else { throw BolusError.validation("Введите значение глюкозы больше 0") }
        let mmol = unit.toMmol(value)
        guard mmol >= 0.5, mmol <= 55 else { throw BolusError.validation("Значение вне допустимых границ. Проверьте единицы.") }
        guard Self.glucoseSources.contains(source), Self.trends.contains(trend) else { throw BolusError.validation("Некорректный источник измерения") }
        try checkNote(note)
        try checkTime(measuredAt)
        return try record(.glucose, measuredAt, GlucosePayload(value: value, unit: unit, source: source, trend: trend, note: note), clientID: clientID)
    }

    // MARK: Insulin

    /// Profile valid at the administration time (`valid_from <= t`, highest version),
    /// otherwise the current active profile.
    public static func profile(at date: Date, in profiles: [TherapyProfileRecord]) -> TherapyProfileRecord? {
        let valid = profiles.filter { $0.validFrom <= date }.max { $0.version < $1.version }
        return valid ?? profiles.filter(\.isActive).max { $0.version < $1.version }
    }

    public func insulin(units: Double, type: InsulinType, name: String = "", purpose: InsulinPurpose = .manual,
                        administeredAt: Date, note: String = "", profiles: [TherapyProfileRecord], clientID: UUID = UUID()) throws -> DiaryRecord {
        guard units.isFinite, units > 0, units <= 200 else { throw BolusError.validation("Доза должна быть больше 0 и не больше 200 ЕД") }
        guard name.count <= 80 else { throw BolusError.validation("Название инсулина длиннее 80 символов") }
        try InsulinCatalog.checkType(name, type)
        guard (type == .basal) == (purpose == .basal) else { throw BolusError.validation("Тип инсулина и назначение должны совпадать") }
        try checkNote(note)
        try checkTime(administeredAt)
        let profile = Self.profile(at: administeredAt, in: profiles)
        if type == .rapid && profile == nil {
            throw BolusError.validation("Настройте DIA в профиле перед записью быстрого инсулина")
        }
        var insulinName = name
        if insulinName.isEmpty, let profile {
            insulinName = type == .rapid ? profile.settings.rapidInsulinName : profile.settings.basalInsulinName
        }
        let metadata = try InsulinCatalog.metadata(insulinName, type)
        let step = profile.map { type == .rapid ? $0.settings.bolusIncrement : $0.settings.basalIncrement } ?? BolusEngine.legacyIncrement
        guard InsulinCatalog.isDoseMultiple(units, step: step) else {
            throw BolusError.validation("Доза должна быть кратна шагу устройства \(BolusFormat.number(step)) ЕД")
        }
        let payload = InsulinPayload(units: units, insulinType: type, insulinName: insulinName, purpose: purpose, note: note,
                                     insulinID: metadata.insulinID, activeIngredient: metadata.activeIngredient, doseIncrement: step,
                                     dia: type == .rapid ? profile?.settings.insulinActionDuration : nil,
                                     actionModel: type == .rapid ? IOBEngine.modelVersion : "basal-excluded")
        return try record(.insulin, administeredAt, payload, clientID: clientID)
    }

    // MARK: Meal

    public static func validate(item: MealItem) throws {
        let name = item.nameSnapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, item.nameSnapshot.count <= 150 else { throw BolusError.validation("Укажите название продукта") }
        guard item.foodSource.count <= 40, item.foodID.count <= 100 else { throw BolusError.validation("Некорректный источник продукта") }
        let values = [item.carbs, item.protein, item.fat, item.calories]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }), item.carbs <= 1000, item.protein <= 1000, item.fat <= 1000, item.calories <= 10000 else {
            throw BolusError.validation("Проверьте пищевую ценность «\(name)»")
        }
        for optional in [item.fiber, item.sugar] {
            if let value = optional, !(value.isFinite && value >= 0 && value <= 1000) {
                throw BolusError.validation("Проверьте клетчатку и сахар «\(name)»")
            }
        }
        guard item.amount.isFinite, item.amount > 0, item.amount <= 10000 else { throw BolusError.validation("Количество «\(name)» должно быть от 0 до 10 000") }
        if let grams = item.grams, !(grams.isFinite && grams > 0 && grams <= 10000) {
            throw BolusError.validation("Масса «\(name)» должна быть от 0 до 10 000 г")
        }
        if item.unit != .ml && item.grams == nil { throw BolusError.validation("Укажите массу продукта в граммах") }
        if item.unit == .g && item.grams != item.amount { throw BolusError.validation("Количество в граммах должно совпадать с массой") }
    }

    public func meal(name: String = "Приём пищи", mealType: MealType = .lunch, eatenAt: Date, items: [MealItem],
                     note: String = "", clientID: UUID = UUID()) throws -> DiaryRecord {
        guard !items.isEmpty else { throw BolusError.validation("Добавьте хотя бы один продукт") }
        guard items.count <= 100 else { throw BolusError.validation("Не больше 100 продуктов в одном приёме пищи") }
        guard name.count <= 150 else { throw BolusError.validation("Название длиннее 150 символов") }
        try items.forEach(Self.validate(item:))
        try checkNote(note)
        try checkTime(eatenAt)
        return try record(.meal, eatenAt, MealPayload(name: name, mealType: mealType, items: items, note: note), clientID: clientID)
    }

    // MARK: Activity and notes

    public func activity(name: String, durationMinutes: Int, occurredAt: Date, intensity: String = "moderate",
                         note: String = "", clientID: UUID = UUID()) throws -> DiaryRecord {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 100 else { throw BolusError.validation("Укажите название активности") }
        guard (1...1440).contains(durationMinutes) else { throw BolusError.validation("Длительность: от 1 до 1440 минут") }
        guard Self.intensities.contains(intensity) else { throw BolusError.validation("Некорректная интенсивность") }
        try checkNote(note)
        try checkTime(occurredAt)
        let payload = ActivityPayload(name: title, durationMinutes: Double(durationMinutes), intensity: intensity, note: note, source: "manual")
        return try record(.activity, occurredAt, payload, clientID: clientID)
    }

    public func note(_ text: String, occurredAt: Date, clientID: UUID = UUID()) throws -> DiaryRecord {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BolusError.validation("Напишите заметку") }
        try checkNote(trimmed)
        try checkTime(occurredAt)
        return try record(.note, occurredAt, NotePayload(note: trimmed), clientID: clientID)
    }

    // MARK: Cycle

    public func cycle(start: LocalDate, length: Int = 28, end: LocalDate? = nil, ovulation: LocalDate? = nil) throws -> CycleRecord {
        guard CycleEngine.allowedLengths.contains(length) else { throw BolusError.validation("Длина цикла: от 15 до 90 дней") }
        if let end, end < start { throw BolusError.validation("Дата окончания раньше начала") }
        if let ovulation, ovulation < start { throw BolusError.validation("Дата овуляции раньше начала") }
        if start > LocalDate.today(in: timeZone, now: now) { throw BolusError.validation("Начало цикла не может быть в будущем") }
        return CycleRecord(startDate: start, endDate: end, cycleLength: length, actualOvulationDate: ovulation, createdAt: now)
    }

    // MARK: Unified form (atomic batch)

    public struct BatchDraft: Equatable, Sendable {
        public var occurredAt: Date
        public var glucose: Double?
        public var glucoseUnit: GlucoseUnit
        public var mealName: String
        public var mealType: MealType
        public var mealItems: [MealItem]
        public var manualCarbs: Double?
        public var rapidUnits: Double?
        public var basalUnits: Double?
        public var activityName: String
        public var activityMinutes: Int?
        public var activityIntensity: String
        public var cycleStart: LocalDate?
        public var cycleLength: Int
        public var note: String

        public init(occurredAt: Date, glucose: Double? = nil, glucoseUnit: GlucoseUnit = .mmol, mealName: String = "Приём пищи",
                    mealType: MealType = .snack, mealItems: [MealItem] = [], manualCarbs: Double? = nil, rapidUnits: Double? = nil,
                    basalUnits: Double? = nil, activityName: String = "", activityMinutes: Int? = nil,
                    activityIntensity: String = "moderate", cycleStart: LocalDate? = nil, cycleLength: Int = 28, note: String = "") {
            self.occurredAt = occurredAt
            self.glucose = glucose
            self.glucoseUnit = glucoseUnit
            self.mealName = mealName
            self.mealType = mealType
            self.mealItems = mealItems
            self.manualCarbs = manualCarbs
            self.rapidUnits = rapidUnits
            self.basalUnits = basalUnits
            self.activityName = activityName
            self.activityMinutes = activityMinutes
            self.activityIntensity = activityIntensity
            self.cycleStart = cycleStart
            self.cycleLength = cycleLength
            self.note = note
        }

        public var isEmpty: Bool {
            glucose == nil && mealItems.isEmpty && manualCarbs == nil && rapidUnits == nil && basalUnits == nil
                && activityMinutes == nil && activityName.trimmingCharacters(in: .whitespaces).isEmpty
                && cycleStart == nil && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public struct BatchResult: Equatable, Sendable {
        public var entries: [DiaryRecord]
        public var cycle: CycleRecord?
        public var count: Int { entries.count + (cycle == nil ? 0 : 1) }
        public var meal: DiaryRecord? { entries.first { $0.kind == .meal } }
        public var glucose: DiaryRecord? { entries.first { $0.kind == .glucose } }
    }

    /// Port of `POST /diary/batch`: every filled section is validated first, nothing
    /// is returned for persistence unless all sections are valid.
    public func batch(_ draft: BatchDraft, profiles: [TherapyProfileRecord]) throws -> BatchResult {
        guard !draft.isEmpty else { throw BolusError.validation("Заполните хотя бы один раздел — например, только глюкозу.") }
        let trimmedActivity = draft.activityName.trimmingCharacters(in: .whitespaces)
        if (draft.activityMinutes == nil) != trimmedActivity.isEmpty {
            throw BolusError.validation("Для активности укажите название и длительность.")
        }
        var entries: [DiaryRecord] = []
        let at = draft.occurredAt
        if let value = draft.glucose {
            entries.append(try glucose(value: value, unit: draft.glucoseUnit, measuredAt: at))
        }
        if !draft.mealItems.isEmpty || draft.manualCarbs != nil {
            var items = draft.mealItems
            if let carbs = draft.manualCarbs {
                items.append(MealItem(nameSnapshot: "Углеводы, введённые вручную", grams: 100, amount: 100, unit: .g, carbs: carbs))
            }
            entries.append(try meal(name: draft.mealName, mealType: draft.mealType, eatenAt: at, items: items))
        }
        if let units = draft.rapidUnits {
            entries.append(try insulin(units: units, type: .rapid, purpose: .manual, administeredAt: at, profiles: profiles))
        }
        if let units = draft.basalUnits {
            entries.append(try insulin(units: units, type: .basal, purpose: .basal, administeredAt: at, profiles: profiles))
        }
        if let minutes = draft.activityMinutes {
            entries.append(try activity(name: trimmedActivity, durationMinutes: minutes, occurredAt: at, intensity: draft.activityIntensity))
        }
        if !draft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entries.append(try note(draft.note, occurredAt: at))
        }
        let cycleRecord = try draft.cycleStart.map { try cycle(start: $0, length: draft.cycleLength) }
        return BatchResult(entries: entries, cycle: cycleRecord)
    }
}
