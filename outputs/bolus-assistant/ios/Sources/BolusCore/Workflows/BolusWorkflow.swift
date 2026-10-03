import Foundation

/// Local version of `POST /bolus/calculate`, `POST /bolus/{id}/confirm` and `GET /iob`.
/// Pure orchestration around the deterministic engine; persistence is the caller's job.
public enum BolusWorkflow {
    /// A calculation can be confirmed for 15 minutes.
    public static let confirmationWindow: TimeInterval = 900
    public static let maxConfirmedUnits = 50.0

    public struct Request: Equatable, Sendable {
        /// Value in `unit`; `nil` = no glucose (calculation will be blocked).
        public var glucose: Double?
        public var unit: GlucoseUnit
        /// Manual carbs; ignored when `meal` is given (meal totals are used).
        public var carbs: Double
        public var measuredAt: Date?
        public var meal: DiaryRecord?

        public init(glucose: Double?, unit: GlucoseUnit, carbs: Double, measuredAt: Date?, meal: DiaryRecord? = nil) {
            self.glucose = glucose
            self.unit = unit
            self.carbs = carbs
            self.measuredAt = measuredAt
            self.meal = meal
        }
    }

    /// Rapid insulin doses that count for IOB at `now` (`current_iob`): actually
    /// administered diary entries from the last 8 hours, with the DIA stored on the entry.
    public static func doses(from entries: [DiaryRecord], at now: Date) -> [AdministeredDose] {
        let start = now.addingTimeInterval(-IOBEngine.lookbackSeconds)
        return entries
            .filter { $0.kind == .insulin && $0.occurredAt >= start && $0.occurredAt <= now }
            .sorted { ($0.occurredAt, $0.createdAt) < ($1.occurredAt, $1.createdAt) }
            .compactMap { entry in
                guard let data = entry.data.objectValue, data["insulin_type"]?.stringValue == InsulinType.rapid.rawValue,
                      let units = data["units"]?.doubleValue else { return nil }
                return AdministeredDose(units: units, administeredAt: entry.occurredAt,
                                        diaHours: data["dia"]?.doubleValue ?? IOBEngine.legacyDefaultDIA, insulinType: .rapid)
            }
    }

    public static func currentIOB(entries: [DiaryRecord], at now: Date) throws -> Double {
        try IOBEngine.calculate(doses(from: entries, at: now), at: now)
    }

    /// Validates the request, assembles the immutable input snapshot and runs the engine.
    /// Blocked results are returned (and should be stored) like in the reference.
    public static func calculate(_ request: Request, profile: TherapyProfileRecord?, insulinEntries: [DiaryRecord],
                                 now: Date, timeZone: TimeZone, id: UUID = UUID()) throws -> BolusCalculationRecord {
        guard let profile, profile.settings.confirmed else {
            throw BolusError.validation("Сначала подтвердите терапевтический профиль")
        }
        if let glucose = request.glucose, !(glucose.isFinite && glucose > 0 && glucose <= 1000) {
            throw BolusError.validation("Проверьте значение глюкозы")
        }
        var carbs = request.carbs
        var mealID: String?
        if let meal = request.meal {
            guard meal.kind == .meal, let total = meal.data.double("total_carbs") else { throw BolusError.validation("Некорректный приём пищи") }
            carbs = total
            mealID = meal.id.uuidString.lowercased()
        } else if !(carbs.isFinite && carbs >= 0 && carbs <= 500) {
            throw BolusError.validation("Углеводы: от 0 до 500 г")
        }
        let settings = profile.settings
        let segment = try TherapySegments.select(settings.segments, localTime: WallClock.hourMinute(now, timeZone: timeZone))
        let iob = try currentIOB(entries: insulinEntries, at: now)
        let rapid = try InsulinCatalog.metadata(settings.rapidInsulinName, .rapid)
        let glucoseMmol = request.glucose.map { request.unit.toMmol($0) }
        let snapshot = BolusInputSnapshot(
            glucose: glucoseMmol, unit: "mmol/L", originalUnit: request.unit.rawValue, originalGlucose: request.glucose,
            carbs: carbs, startTime: segment.startTime, endTime: segment.endTime, icr: segment.icr, isf: segment.isf,
            target: segment.target, correctAbove: segment.correctAbove, dia: settings.insulinActionDuration,
            maxBolus: settings.maxBolus, iob: iob, measuredAt: request.measuredAt.map { ISODate.format($0) },
            calculatedAt: ISODate.format(now), timezone: timeZone.identifier, profileID: profile.id.uuidString.lowercased(),
            profileVersion: profile.version, mealID: mealID, iobModel: IOBEngine.modelVersion,
            bolusIncrement: settings.bolusIncrement, rapidInsulinName: settings.rapidInsulinName,
            basalInsulinName: settings.basalInsulinName, insulinID: rapid.insulinID, activeIngredient: rapid.activeIngredient,
            insulinType: rapid.insulinType.rawValue)
        let input = BolusEngine.Input(glucose: glucoseMmol, unit: "mmol/L", carbs: carbs, icr: segment.icr, isf: segment.isf,
                                      target: segment.target, correctAbove: segment.correctAbove, dia: settings.insulinActionDuration,
                                      iob: iob, maxBolus: settings.maxBolus, measuredAt: request.measuredAt,
                                      bolusIncrement: settings.bolusIncrement)
        let result = BolusEngine.calculate(input, at: now)
        return BolusCalculationRecord(id: id, calculatedAt: now, inputSnapshot: try JSONValue.encode(snapshot),
                                      calculationSnapshot: try JSONValue.encode(result), algorithmVersion: BolusEngine.algorithmVersion)
    }

    public enum Confirmation: Equatable, Sendable {
        /// Idempotent repeat: the dose is already stored.
        case alreadyConfirmed(entryID: UUID?, units: Double)
        /// New insulin entry plus the calculation with the actual dose attached.
        case confirmed(entry: DiaryRecord, calculation: BolusCalculationRecord)
    }

    public static func dedupeKey(for calculation: BolusCalculationRecord) -> String {
        "bolus:" + calculation.id.uuidString.lowercased()
    }

    /// Records the actually administered dose separately from the recommendation.
    public static func confirm(_ calculation: BolusCalculationRecord, actualUnits: Double, administeredAt: Date, now: Date,
                               profiles: [TherapyProfileRecord]) throws -> Confirmation {
        if let actual = calculation.actualBolus {
            return .alreadyConfirmed(entryID: calculation.confirmedEntryID, units: actual)
        }
        guard calculation.result?.calculationStatus == .ok, let snapshot = calculation.input else {
            throw BolusError.conflict("Расчёт заблокирован")
        }
        if now.timeIntervalSince(calculation.calculatedAt) > confirmationWindow {
            throw BolusError.conflict("Расчёт устарел. Выполните новый расчёт.")
        }
        if administeredAt < calculation.calculatedAt.addingTimeInterval(-60) || administeredAt > now.addingTimeInterval(60) {
            throw BolusError.validation("Проверьте время введения")
        }
        guard actualUnits.isFinite, actualUnits > 0, actualUnits <= maxConfirmedUnits else {
            throw BolusError.validation("Фактическая доза должна быть больше 0 и не больше 50 ЕД")
        }
        if actualUnits > snapshot.maxBolus {
            throw BolusError.validation("Превышен максимальный болюс. Для исторического факта используйте ручную запись.")
        }
        let step = snapshot.bolusIncrement ?? BolusEngine.legacyIncrement
        guard InsulinCatalog.isDoseMultiple(actualUnits, step: step) else {
            throw BolusError.validation("Доза должна быть кратна шагу устройства \(BolusFormat.number(step)) ЕД")
        }
        let profile = profiles.first { $0.id.uuidString.lowercased() == snapshot.profileID.lowercased() }
        let name = profile?.settings.rapidInsulinName ?? snapshot.rapidInsulinName
        let metadata = try InsulinCatalog.metadata(name, .rapid)
        let payload = InsulinPayload(units: actualUnits, insulinType: .rapid, insulinName: name,
                                     purpose: snapshot.carbs != 0 ? .mealAndCorrection : .correction, note: "",
                                     insulinID: metadata.insulinID, activeIngredient: metadata.activeIngredient,
                                     doseIncrement: step, dia: snapshot.dia, actionModel: snapshot.iobModel,
                                     relatedBolusCalculationID: calculation.id.uuidString.lowercased(),
                                     relatedMealID: snapshot.mealID)
        let entry = DiaryRecord(kind: .insulin, occurredAt: administeredAt, data: try JSONValue.encode(payload), createdAt: now,
                                dedupeKey: dedupeKey(for: calculation))
        var updated = calculation
        updated.actualBolus = actualUnits
        updated.confirmedEntryID = entry.id
        return .confirmed(entry: entry, calculation: updated)
    }
}

/// Therapy profile versioning (`PUT /profile`): a new version is created, the active
/// one is archived; historical versions are never modified retroactively.
public enum ProfileWorkflow {
    static let diabetesTypes: Set<String> = ["type1", "type2", "other"]
    static let therapyTypes: Set<String> = ["MDI", "PUMP", "OTHER"]

    public static func validate(_ settings: TherapySettings) throws -> TherapySettings {
        guard settings.confirmed else { throw BolusError.validation("Подтвердите параметры профиля") }
        guard diabetesTypes.contains(settings.diabetesType), therapyTypes.contains(settings.insulinTherapyType) else {
            throw BolusError.validation("Проверьте тип диабета и терапии")
        }
        guard settings.rapidInsulinName.count <= 80, settings.basalInsulinName.count <= 80 else {
            throw BolusError.validation("Название инсулина длиннее 80 символов")
        }
        guard InsulinCatalog.doseSteps.contains(settings.bolusIncrement), InsulinCatalog.doseSteps.contains(settings.basalIncrement) else {
            throw BolusError.validation("Допустимый шаг: 0,1; 0,25; 0,5; 1 или 2 ЕД")
        }
        guard settings.maxBolus.isFinite, settings.maxBolus > 0, settings.maxBolus <= 50 else {
            throw BolusError.validation("Максимальный болюс: больше 0 и не больше 50 ЕД")
        }
        guard settings.insulinActionDuration.isFinite, settings.insulinActionDuration >= 2, settings.insulinActionDuration <= 8 else {
            throw BolusError.validation("DIA: от 2 до 8 часов")
        }
        try InsulinCatalog.checkType(settings.rapidInsulinName, .rapid)
        try InsulinCatalog.checkType(settings.basalInsulinName, .basal)
        var result = settings
        result.segments = try TherapySegments.validated(settings.segments)
        return result
    }

    public static func active(_ profiles: [TherapyProfileRecord]) -> TherapyProfileRecord? {
        profiles.filter(\.isActive).max { $0.version < $1.version }
    }

    /// Returns the new active version and the archived previous one (if any).
    public static func newVersion(_ settings: TherapySettings, existing: [TherapyProfileRecord], now: Date,
                                  source: String = "manual") throws -> (profile: TherapyProfileRecord, archived: TherapyProfileRecord?) {
        let valid = try validate(settings)
        var archived = active(existing)
        archived?.status = "archived"
        archived?.validTo = now
        let version = (existing.map(\.version).max() ?? 0) + 1
        let profile = TherapyProfileRecord(version: version, validFrom: now, status: "active", source: source, settings: valid)
        return (profile, archived)
    }
}
