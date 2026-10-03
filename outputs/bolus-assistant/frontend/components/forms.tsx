"use client";
import { useEffect, useState } from "react";
import {
  Plus,
  Search,
  Trash2,
  Heart,
  Upload,
  Check,
  ShieldCheck,
  Calculator,
  Clock,
  ArrowRight,
  Info,
  Camera,
} from "lucide-react";
import { api, post, decimal, localDate, newId } from "@/services/api";
import { saveOrQueue } from "@/services/offline";
import { Field, Submit, ErrorBox } from "./ui";
const nowLocal = () => {
  const d = new Date();
  return new Date(d.getTime() - d.getTimezoneOffset() * 60000)
    .toISOString()
    .slice(0, 16);
};
const iso = (v: string) => new Date(v).toISOString();
function useForm() {
  const [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  return {
    busy,
    error,
    run: async (fn: () => Promise<void>) => {
      setBusy(true);
      setError("");
      try {
        await fn();
      } catch (e) {
        setError(e instanceof Error ? e.message : "Не удалось сохранить");
      } finally {
        setBusy(false);
      }
    },
  };
}
export function EntryForm({ kind, user, profile, onSaved }: any) {
  const [value, setValue] = useState(""),
    [time, setTime] = useState(nowLocal()),
    [note, setNote] = useState(""),
    [name, setName] = useState(
      kind === "activity" ? "Ходьба" : profile?.rapid_insulin_name || "",
    ),
    [type, setType] = useState("rapid"),
    [purpose, setPurpose] = useState("manual"),
    [intensity, setIntensity] = useState("moderate");
  const { busy, error, run } = useForm();
  return (
    <form
      className="form"
      onSubmit={(e) => {
        e.preventDefault();
        run(async () => {
          const payload: any = { client_id: newId(), note };
          let path = "";
          if (kind === "glucose") {
            path = "/glucose";
            Object.assign(payload, {
              value: Number(value),
              unit: user.glucose_unit,
              measured_at: iso(time),
              source: "manual",
              trend: "unknown",
            });
          }
          if (kind === "insulin") {
            path = "/insulin";
            Object.assign(payload, {
              units: Number(value),
              insulin_type: type,
              insulin_name: name,
              purpose: type === "basal" ? "basal" : purpose,
              administered_at: iso(time),
            });
          }
          if (kind === "activity") {
            path = "/activity";
            Object.assign(payload, {
              name,
              duration_minutes: Number(value),
              intensity,
              occurred_at: iso(time),
            });
          }
          if (kind === "note") {
            path = "/notes";
            Object.assign(payload, { occurred_at: iso(time) });
          }
          const result = await saveOrQueue(user.id, path, payload);
          await onSaved(
            result.queued
              ? "Сохранено на устройстве. Отправим после подключения."
              : "Запись сохранена",
          );
        });
      }}
    >
      {kind === "glucose" && (
        <Field
          label={`Глюкоза, ${user.glucose_unit === "mg/dL" ? "мг/дл" : "ммоль/л"}`}
        >
          <input
            autoFocus
            className="large-input"
            required
            type="number"
            inputMode="decimal"
            min={user.glucose_unit === "mg/dL" ? 9 : 0.5}
            max={user.glucose_unit === "mg/dL" ? 990 : 55}
            step="0.1"
            placeholder={user.glucose_unit === "mg/dL" ? "122" : "6.8"}
            value={value}
            onChange={(e) => setValue(e.target.value)}
          />
        </Field>
      )}
      {kind === "insulin" && (
        <>
          <div className="two-fields">
            <Field label="Тип инсулина">
              <select
                value={type}
                onChange={(e) => {
                  setType(e.target.value);
                  setName(
                    e.target.value === "basal"
                      ? profile?.basal_insulin_name || ""
                      : profile?.rapid_insulin_name || "",
                  );
                }}
              >
                <option value="rapid">Быстрый</option>
                <option value="basal">Базальный</option>
              </select>
            </Field>
            <Field label="Фактически введено, ЕД">
              <input
                required
                type="number"
                inputMode="decimal"
                min="0.1"
                max="200"
                step="0.1"
                value={value}
                onChange={(e) => setValue(e.target.value)}
              />
            </Field>
          </div>
          <Field label="Название инсулина">
            <input
              maxLength={80}
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Название препарата"
            />
          </Field>
          {type === "rapid" && (
            <Field label="Назначение">
              <select
                value={purpose}
                onChange={(e) => setPurpose(e.target.value)}
              >
                <option value="manual">Ручная запись</option>
                <option value="meal">На еду</option>
                <option value="correction">Коррекция</option>
                <option value="meal_and_correction">Еда и коррекция</option>
              </select>
            </Field>
          )}
          <div className="subtle-note">
            Записывайте только уже введённый инсулин. Эта запись учитывается в
            IOB.
          </div>
        </>
      )}
      {kind === "activity" && (
        <>
          <Field label="Активность">
            <input
              required
              maxLength={100}
              value={name}
              onChange={(e) => setName(e.target.value)}
            />
          </Field>
          <div className="two-fields">
            <Field label="Длительность, мин">
              <input
                type="number"
                required
                min="1"
                max="1440"
                value={value}
                onChange={(e) => setValue(e.target.value)}
              />
            </Field>
            <Field label="Интенсивность">
              <select
                value={intensity}
                onChange={(e) => setIntensity(e.target.value)}
              >
                <option value="low">Лёгкая</option>
                <option value="moderate">Умеренная</option>
                <option value="high">Высокая</option>
              </select>
            </Field>
          </div>
        </>
      )}
      <Field label="Дата и время" hint="В часовом поясе этого устройства">
        <input
          type="datetime-local"
          required
          value={time}
          max={nowLocal()}
          onChange={(e) => setTime(e.target.value)}
        />
      </Field>
      <Field
        label={kind === "note" ? "Ваша заметка" : "Заметка · необязательно"}
      >
        <textarea
          required={kind === "note"}
          maxLength={2000}
          rows={3}
          placeholder="Что хочется отметить?"
          value={note}
          onChange={(e) => setNote(e.target.value)}
        />
      </Field>
      <ErrorBox message={error} />
      <Submit busy={busy}>Сохранить запись</Submit>
    </form>
  );
}

export function FoodPicker({ onPick }: { onPick: (food: any) => void }) {
  const [q, setQ] = useState(""),
    [source, setSource] = useState("search"),
    [foods, setFoods] = useState<any[]>([]),
    [loading, setLoading] = useState(false),
    [error, setError] = useState(""),
    [warnings, setWarnings] = useState<string[]>([]);
  useEffect(() => {
    let active = true;
    const id = setTimeout(async () => {
      setLoading(true);
      try {
        const result = await api(
          source === "search"
            ? "/foods/search?q=" + encodeURIComponent(q)
            : "/foods/" + source,
        );
        if (active) {
          setFoods(
            source === "search"
              ? result.foods
              : result.filter((f: any) =>
                  f.name.toLowerCase().includes(q.toLowerCase()),
                ),
          );
          setError("");
          setWarnings(source === "search" ? result.warnings || [] : []);
        }
      } catch (e) {
        if (active) {
          setFoods([]);
          setWarnings([]);
          setError((e as Error).message);
        }
      } finally {
        if (active) setLoading(false);
      }
    }, 400);
    return () => {
      active = false;
      clearTimeout(id);
    };
  }, [q, source]);
  return (
    <div className="food-picker">
      <div className="food-source-tabs">
        {[
          ["search", "Все продукты"],
          ["recent", "Недавние"],
          ["favorites", "Избранное"],
        ].map(([id, label]) => (
          <button
            type="button"
            key={id}
            className={source === id ? "active" : ""}
            onClick={() => setSource(id)}
          >
            {label}
          </button>
        ))}
      </div>
      <div className="search-input">
        <Search size={18} />
        <input
          aria-label="Поиск продуктов"
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder="Продукт, блюдо или бренд"
        />
      </div>
      <div className="food-results">
        {loading ? (
          <div className="loading-state">Ищем продукты…</div>
        ) : foods.length ? (
          foods.map((f) => (
            <button
              type="button"
              key={f.provider + f.external_id}
              onClick={() => onPick(f)}
            >
              <span>
                <b>{f.name}</b>
                <small>
                  {f.brand || f.provider} · {f.serving_weight || 100}{" "}
                  {foodUnit(f)}
                </small>
              </span>
              <span>
                {decimal(f.carbs)} г угл.
                <Plus size={17} />
              </span>
            </button>
          ))
        ) : (
          <p className="subtle-note">
            {q.trim().length < 2 && source === "search"
              ? "Введите от двух букв для поиска в YAZIO и своих продуктах."
              : "Продукт не найден. Создайте свой на экране «Питание»."}
          </p>
        )}
      </div>
      <ErrorBox message={error} />
      {warnings.map((warning) => (
        <p key={warning} className="subtle-note" role="status">
          {warning}
        </p>
      ))}
      <small className="catalog-note">
        YAZIO и ваши продукты. Значения на 100 г или 100 мл. Сверяйте состав с
        упаковкой.
      </small>
    </div>
  );
}
export function foodUnit(food: any) {
  return food.base_unit === "ml" ? "мл" : "г";
}
export function makeItem(food: any, amount = 100) {
  const scale = amount / (food.serving_weight || 100);
  const unit = food.base_unit === "ml" ? "ml" : "g";
  return {
    name_snapshot: food.name,
    food_source: food.provider || "custom",
    food_id: food.external_id || food.id || "",
    grams: unit === "g" ? amount : null,
    amount,
    unit,
    ...Object.fromEntries(
      ["carbs", "protein", "fat", "calories", "fiber", "sugar"].map((k) => [
        k,
        (k === "fiber" || k === "sugar") && food[k] == null
          ? null
          : (food[k] || 0) * scale,
      ]),
    ),
    _food: food,
  };
}
export const cleanItem = (i: any) => {
  const { _food, ...clean } = i;
  return clean;
};
export function Ingredients({
  items,
  setItems,
}: {
  items: any[];
  setItems: (i: any[]) => void;
}) {
  return (
    <div className="ingredients">
      {items.map((item, n) => (
        <div className="ingredient" key={n}>
          <div>
            <b>{item.name_snapshot}</b>
            <small>
              {decimal(item.carbs)} г угл. · {decimal(item.calories, 0)} ккал
            </small>
          </div>
          <label>
            <input
              aria-label={`Количество ${item.name_snapshot}, ${item.unit === "ml" ? "мл" : "г"}`}
              required
              type="number"
              min="1"
              max="10000"
              step="1"
              value={item.amount}
              onChange={(e) =>
                setItems(
                  items.map((i, index) =>
                    index === n ? makeItem(i._food, Number(e.target.value)) : i,
                  ),
                )
              }
            />
            <span>{item.unit === "ml" ? "мл" : "г"}</span>
          </label>
          <button
            type="button"
            className="icon-button"
            aria-label={`Убрать ${item.name_snapshot}`}
            onClick={() => setItems(items.filter((_, index) => index !== n))}
          >
            <Trash2 size={16} />
          </button>
        </div>
      ))}
    </div>
  );
}
export function MealForm({ user, onSaved, onBolus }: any) {
  const [items, setItems] = useState<any[]>([]),
    [name, setName] = useState("Обед"),
    [type, setType] = useState("lunch"),
    [time, setTime] = useState(nowLocal()),
    [mode, setMode] = useState("save");
  const { busy, error, run } = useForm();
  const total = (key: string) => items.reduce((s, i) => s + i[key], 0);
  return (
    <form
      className="form"
      onSubmit={(e) => {
        e.preventDefault();
        run(async () => {
          if (!items.length) throw new Error("Добавьте хотя бы один продукт");
          const meal = await saveOrQueue(user.id, "/meals", {
            name,
            meal_type: type,
            eaten_at: iso(time),
            items: items.map(cleanItem),
            note: "",
            client_id: newId(),
          });
          if (mode === "bolus" && !meal.queued) await onBolus(meal);
          else
            await onSaved(
              meal.queued
                ? "Черновик еды сохранён на устройстве"
                : "Приём пищи сохранён",
            );
        });
      }}
    >
      <div className="two-fields">
        <Field label="Название">
          <input
            required
            value={name}
            maxLength={150}
            onChange={(e) => setName(e.target.value)}
          />
        </Field>
        <Field label="Приём пищи">
          <select
            value={type}
            onChange={(e) => {
              setType(e.target.value);
              setName(
                (
                  {
                    breakfast: "Завтрак",
                    lunch: "Обед",
                    dinner: "Ужин",
                    snack: "Перекус",
                  } as any
                )[e.target.value],
              );
            }}
          >
            <option value="breakfast">Завтрак</option>
            <option value="lunch">Обед</option>
            <option value="dinner">Ужин</option>
            <option value="snack">Перекус</option>
          </select>
        </Field>
      </div>
      <FoodPicker onPick={(f) => setItems([...items, makeItem(f)])} />
      <Ingredients items={items} setItems={setItems} />
      <div className="nutrition-total">
        {[
          ["Углеводы", "carbs", "г"],
          ["Белки", "protein", "г"],
          ["Жиры", "fat", "г"],
          ["Энергия", "calories", "ккал"],
        ].map(([label, k, unit]) => (
          <div key={k}>
            <span>{label}</span>
            <b>
              {decimal(total(k))} <small>{unit}</small>
            </b>
          </div>
        ))}
      </div>
      <Field label="Когда ели" hint="В часовом поясе устройства">
        <input
          type="datetime-local"
          required
          max={nowLocal()}
          value={time}
          onChange={(e) => setTime(e.target.value)}
        />
      </Field>
      <ErrorBox message={error} />
      <div className="form-actions">
        <button
          className="secondary"
          type="submit"
          disabled={busy}
          onClick={() => setMode("save")}
        >
          Сохранить еду
        </button>
        <button
          className="primary"
          type="submit"
          disabled={busy || !items.length}
          onClick={() => setMode("bolus")}
        >
          <Calculator size={17} />
          {busy ? "Сохраняем…" : "К расчёту болюса"}
        </button>
      </div>
    </form>
  );
}

const warningNames: any = {
  missing_glucose: "Введите актуальную глюкозу.",
  invalid_glucose: "Проверьте значение глюкозы.",
  extreme_glucose:
    "Глюкоза вне границ расчёта (3,9–30 ммоль/л). Следуйте вашему согласованному плану действий.",
  stale_glucose: "Измерению больше 15 минут. Нужна свежая глюкоза.",
  future_glucose: "Время измерения находится в будущем.",
  max_bolus_exceeded: "Результат превышает максимальный болюс вашего профиля.",
  invalid_icr: "Проверьте ICR в профиле.",
  invalid_isf: "Проверьте ISF в профиле.",
  unexpected_iob: "IOB вне допустимых границ.",
  unit_mismatch: "Проверьте единицы измерения.",
  below_target: "Глюкоза ниже целевого значения: итог уменьшен.",
};
export function BolusForm({
  user,
  profile,
  latest,
  meal,
  offline,
  clinicalUseEnabled = false,
  onExplain,
  draft,
  onSaved,
  onProfile,
}: any) {
  const [glucose, setGlucose] = useState(
      latest
        ? String(
            Math.round(
              latest.data.value_mmol *
                (user.glucose_unit === "mg/dL" ? 18 : 1) *
                10,
            ) / 10,
          )
        : "",
    ),
    [carbs, setCarbs] = useState(meal ? String(meal.data.total_carbs) : ""),
    [measured, setMeasured] = useState(
      latest
        ? new Date(
            new Date(latest.occurred_at).getTime() -
              new Date().getTimezoneOffset() * 60000,
          )
            .toISOString()
            .slice(0, 16)
        : nowLocal(),
    ),
    [result, setResult] = useState<any>(null),
    [actual, setActual] = useState(""),
    [actualTime, setActualTime] = useState(nowLocal());
  const { busy, error, run } = useForm();
  useEffect(() => {
    if (!draft) return;
    setGlucose(draft.glucose);
    setCarbs(draft.carbs);
    setMeasured(draft.measured);
    setResult(null);
    setActual("");
  }, [draft?.glucose, draft?.carbs, draft?.measured, draft?.revision]);
  if (!profile)
    return (
      <div className="form">
        <div className="info-box">
          Сначала настройте и подтвердите ICR, ISF, цель и время действия
          инсулина.
        </div>
        <button className="primary full" onClick={onProfile}>
          Настроить профиль
        </button>
      </div>
    );
  return (
    <div className="form">
      <div className="info-box">
        <ShieldCheck size={19} />
        <span>
          {clinicalUseEnabled
            ? `Расчёт по вашему профилю · ${profile.rapid_insulin_name || "быстрый инсулин"}`
            : "Расчёт отключён в настройках этой установки."}
        </span>
      </div>
      {offline && (
        <ErrorBox message="Расчёт болюса офлайн недоступен: нельзя проверить актуальный IOB." />
      )}
      {!result ? (
        <form
          className="form"
          onSubmit={(e) => {
            e.preventDefault();
            run(async () => {
              const r = await post("/bolus/calculate", {
                glucose: Number(glucose),
                unit: user.glucose_unit,
                carbs: Number(carbs),
                timestamp: new Date().toISOString(),
                measured_at: iso(measured),
                meal_id: meal?.id || null,
              });
              setResult(r);
              setActual("");
              setActualTime(nowLocal());
            });
          }}
        >
          <div className="two-fields">
            <Field
              label={`Глюкоза, ${user.glucose_unit === "mg/dL" ? "мг/дл" : "ммоль/л"}`}
            >
              <input
                required
                min="0.1"
                max="1000"
                type="number"
                step="0.1"
                inputMode="decimal"
                value={glucose}
                onChange={(e) => setGlucose(e.target.value)}
                autoFocus={!draft}
              />
            </Field>
            <Field label="Углеводы, г">
              <input
                required
                min="0"
                max="500"
                type="number"
                step="0.1"
                inputMode="decimal"
                value={carbs}
                onChange={(e) => setCarbs(e.target.value)}
                readOnly={!!meal}
              />
            </Field>
          </div>
          {meal && (
            <p className="subtle-note">
              Еда: {meal.data.name}. Углеводы берутся из сохранённой записи.
            </p>
          )}
          <Field label="Время измерения глюкозы">
            <input
              type="datetime-local"
              required
              value={measured}
              max={nowLocal()}
              onChange={(e) => setMeasured(e.target.value)}
            />
          </Field>
          <div className="profile-reference">
            <Clock size={16} />
            <span>
              Профиль v{profile.version} · DIA {profile.insulin_action_duration}{" "}
              ч · лимит {profile.max_bolus} ЕД · шаг{" "}
              {decimal(profile.bolus_increment ?? 0.1)} ЕД
            </span>
          </div>
          <ErrorBox message={error} />
          <button
            className="primary full"
            type="submit"
            disabled={busy || offline || !clinicalUseEnabled}
          >
            {busy ? "Рассчитываем…" : "Рассчитать"}
          </button>
        </form>
      ) : (
        <>
          <div
            className={
              "bolus-result " +
              (result.calculation_status === "blocked" ? "blocked" : "")
            }
          >
            <span>
              {result.calculation_status === "blocked"
                ? "Расчёт заблокирован"
                : "Рассчитанный болюс"}
            </span>
            <strong>
              {result.calculation_status === "blocked"
                ? "—"
                : decimal(result.recommended_bolus)}{" "}
              <small>ЕД</small>
            </strong>
          </div>
          <div className="breakdown">
            <div>
              <span>Еда</span>
              <b>+{decimal(result.meal_bolus, 2)}</b>
            </div>
            <div>
              <span>Коррекция</span>
              <b>
                {result.correction_bolus >= 0 ? "+" : ""}
                {decimal(result.correction_bolus, 2)}
              </b>
            </div>
            <div>
              <span>Активный инсулин</span>
              <b>−{decimal(result.iob_adjustment, 2)}</b>
            </div>
            <div className="breakdown-total">
              <span>
                Итого · шаг {decimal(result.rounding_increment)} ЕД, округление
                вниз
              </span>
              <b>{decimal(result.recommended_bolus)} ЕД</b>
            </div>
            {result.rounding_adjustment > 0 && (
              <div>
                <span>До округления</span>
                <b>{decimal(result.unrounded_bolus, 3)} ЕД</b>
              </div>
            )}
          </div>
          {result.warnings.map((w: string) => (
            <div
              key={w}
              className={
                result.calculation_status === "blocked"
                  ? "error-box"
                  : "info-box"
              }
            >
              {warningNames[w] || w}
            </div>
          ))}
          {result.calculation_status === "ok" && (
            <form
              className="form"
              onSubmit={(e) => {
                e.preventDefault();
                run(async () => {
                  await post("/bolus/" + result.calculation_id + "/confirm", {
                    actual_units: Number(actual),
                    administered_at: iso(actualTime),
                  });
                  await onSaved(
                    "Фактическая доза сохранена отдельно от расчёта",
                  );
                });
              }}
            >
              <Field
                label="Фактически введено, ЕД"
                hint="Введите самостоятельно. Сохраняется отдельно от рекомендации."
              >
                <input
                  required
                  type="number"
                  min={result.rounding_increment}
                  max={profile.max_bolus}
                  step={result.rounding_increment}
                  value={actual}
                  onChange={(e) => setActual(e.target.value)}
                  placeholder="0.0"
                />
              </Field>
              <Field label="Время введения">
                <input
                  type="datetime-local"
                  required
                  value={actualTime}
                  max={nowLocal()}
                  onChange={(e) => setActualTime(e.target.value)}
                />
              </Field>
              <ErrorBox message={error} />
              <Submit busy={busy}>Сохранить фактическую дозу</Submit>
            </form>
          )}
          <button
            className="text-button centered"
            onClick={() => setResult(null)}
          >
            Вернуться к параметрам
          </button>
          <small className="algorithm-note">
            {result.algorithm_version} ·{" "}
            {result.insulin_name || "Быстрый инсулин"} · IOB: линейная модель
          </small>
          {onExplain && (
            <button
              className="secondary full"
              type="button"
              onClick={() => onExplain(result.calculation_id)}
            >
              Объяснить расчёт с AI
            </button>
          )}
        </>
      )}
    </div>
  );
}

export function CycleForm({ user, onSaved }: any) {
  const [start, setStart] = useState(localDate(new Date(), user.timezone)),
    [length, setLength] = useState("28");
  const { busy, error, run } = useForm();
  return (
    <form
      className="form"
      onSubmit={(e) => {
        e.preventDefault();
        run(async () => {
          await post("/cycle", {
            start_date: start,
            cycle_length: Number(length),
          });
          await onSaved("Начало цикла сохранено");
        });
      }}
    >
      <Field label="Первый день менструации">
        <input
          required
          type="date"
          value={start}
          max={localDate(new Date(), user.timezone)}
          onChange={(e) => setStart(e.target.value)}
        />
      </Field>
      <Field label="Обычная длина цикла, дней">
        <input
          required
          type="number"
          min="15"
          max="90"
          value={length}
          onChange={(e) => setLength(e.target.value)}
        />
      </Field>
      <div className="subtle-note">
        Фазы рассчитываются приблизительно. Данные цикла не меняют дозу
        инсулина.
      </div>
      <ErrorBox message={error} />
      <Submit busy={busy}>Сохранить</Submit>
    </form>
  );
}
export function AuthForm({ onSuccess }: any) {
  const [register, setRegister] = useState(true),
    [email, setEmail] = useState(""),
    [password, setPassword] = useState(""),
    [name, setName] = useState("");
  const { busy, error, run } = useForm();
  return (
    <form
      className="form"
      onSubmit={(e) => {
        e.preventDefault();
        run(async () => {
          const u = await post(register ? "/auth/register" : "/auth/login", {
            email,
            password,
            name: register ? name : "Мой дневник",
          });
          await onSuccess(u);
        });
      }}
    >
      <div className="segmented large">
        <button
          type="button"
          className={register ? "selected" : ""}
          onClick={() => setRegister(true)}
        >
          Создать дневник
        </button>
        <button
          type="button"
          className={!register ? "selected" : ""}
          onClick={() => setRegister(false)}
        >
          Войти
        </button>
      </div>
      {register && (
        <Field label="Как вас зовут?">
          <input
            required
            maxLength={80}
            autoComplete="given-name"
            value={name}
            onChange={(e) => setName(e.target.value)}
          />
        </Field>
      )}
      <Field label="Email">
        <input
          required
          type="email"
          autoComplete="email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
        />
      </Field>
      <Field label="Пароль" hint="Не менее 12 символов">
        <input
          required
          type="password"
          minLength={12}
          maxLength={128}
          autoComplete={register ? "new-password" : "current-password"}
          value={password}
          onChange={(e) => setPassword(e.target.value)}
        />
      </Field>
      <ErrorBox message={error} />
      <Submit busy={busy}>{register ? "Создать дневник" : "Войти"}</Submit>
    </form>
  );
}

export function ProfileForm({ profile, onSaved }: any) {
  const blank = {
    diabetes_type: "type1",
    insulin_therapy_type: "MDI",
    rapid_insulin_name: "Фиасп",
    basal_insulin_name: "Тресиба",
    bolus_increment: 1,
    basal_increment: 1,
    max_bolus: "",
    insulin_action_duration: "",
    segments: [
      {
        start_time: "00:00",
        end_time: "24:00",
        icr: "",
        isf: "",
        target: "",
        correct_above: "",
      },
    ],
  };
  const [data, setData] = useState<any>(
      profile
        ? { bolus_increment: 0.1, basal_increment: 0.1, ...profile }
        : blank,
    ),
    [confirm, setConfirm] = useState(false);
  const { busy, error, run } = useForm();
  const change = (k: string, v: any) => {
    setData({ ...data, [k]: v });
    setConfirm(false);
  };
  const segment = (index: number, key: string, value: any) => {
    change(
      "segments",
      data.segments.map((s: any, i: number) =>
        i === index ? { ...s, [key]: value } : s,
      ),
    );
  };
  return (
    <form
      className="form"
      onSubmit={(e) => {
        e.preventDefault();
        run(async () => {
          const payload = {
            diabetes_type: data.diabetes_type,
            insulin_therapy_type: data.insulin_therapy_type,
            rapid_insulin_name: data.rapid_insulin_name,
            basal_insulin_name: data.basal_insulin_name,
            bolus_increment: Number(data.bolus_increment),
            basal_increment: Number(data.basal_increment),
            max_bolus: Number(data.max_bolus),
            insulin_action_duration: Number(data.insulin_action_duration),
            confirmed: confirm,
            segments: data.segments.map((s: any) => ({
              ...s,
              icr: Number(s.icr),
              isf: Number(s.isf),
              target: Number(s.target),
              correct_above: Number(s.correct_above),
            })),
          };
          await api("/profile", {
            method: "PUT",
            body: JSON.stringify(payload),
          });
          await onSaved("Новая версия профиля сохранена");
        });
      }}
    >
      <div className="two-fields">
        <Field label="Тип диабета">
          <select
            value={data.diabetes_type}
            onChange={(e) => change("diabetes_type", e.target.value)}
          >
            <option value="type1">1 тип</option>
            <option value="type2">2 тип</option>
            <option value="other">Другой</option>
          </select>
        </Field>
        <Field label="Терапия">
          <select
            value={data.insulin_therapy_type}
            onChange={(e) => change("insulin_therapy_type", e.target.value)}
          >
            <option value="MDI">Инъекции (MDI)</option>
            <option value="PUMP">Помпа</option>
            <option value="OTHER">Другая</option>
          </select>
        </Field>
        <Field
          label="Быстрый инсулин"
          hint="Фиасп / Fiasp — инсулин аспарт, используется для болюса и IOB."
        >
          <input
            maxLength={80}
            value={data.rapid_insulin_name}
            onChange={(e) => change("rapid_insulin_name", e.target.value)}
          />
        </Field>
        <Field
          label="Базальный инсулин"
          hint="Тресиба / Tresiba — инсулин деглудек, учитывается отдельно от болюсного IOB."
        >
          <input
            maxLength={80}
            value={data.basal_insulin_name}
            onChange={(e) => change("basal_insulin_name", e.target.value)}
          />
        </Field>
        <Field label="Шаг болюсного устройства, ЕД">
          <select
            value={data.bolus_increment}
            onChange={(e) => change("bolus_increment", Number(e.target.value))}
          >
            {[1, 0.5, 0.25, 0.1].map((v) => (
              <option key={v} value={v}>
                {decimal(v)} ЕД
              </option>
            ))}
          </select>
        </Field>
        <Field label="Шаг базальной ручки, ЕД">
          <select
            value={data.basal_increment}
            onChange={(e) => change("basal_increment", Number(e.target.value))}
          >
            {[1, 2, 0.5, 0.25, 0.1].map((v) => (
              <option key={v} value={v}>
                {decimal(v)} ЕД
              </option>
            ))}
          </select>
        </Field>
        <Field
          label="DIA, часов"
          hint="Ваше настроенное время действия быстрого инсулина; название препарата не меняет его автоматически."
        >
          <input
            required
            type="number"
            min="2"
            max="8"
            step="0.5"
            value={data.insulin_action_duration}
            onChange={(e) => change("insulin_action_duration", e.target.value)}
          />
        </Field>
        <Field label="Максимальный болюс, ЕД">
          <input
            required
            type="number"
            min="0.1"
            max="50"
            step="0.1"
            value={data.max_bolus}
            onChange={(e) => change("max_bolus", e.target.value)}
          />
        </Field>
      </div>
      <div className="form-section-title">
        Профили в течение суток{" "}
        <button
          type="button"
          className="text-button"
          onClick={() =>
            change("segments", [
              ...data.segments,
              {
                start_time: "18:00",
                end_time: "24:00",
                icr: "",
                isf: "",
                target: "",
                correct_above: "",
              },
            ])
          }
        >
          <Plus size={15} />
          Период
        </button>
      </div>
      <p className="subtle-note">
        ISF, цель и порог — в ммоль/л, независимо от единиц дневника. Периоды
        должны покрывать 00:00–24:00 без разрывов.
      </p>
      {data.segments.map((s: any, i: number) => (
        <div className="segment-editor" key={i}>
          <div className="two-fields">
            <Field label="С">
              <input
                required
                pattern="([01][0-9]|2[0-3]):[0-5][0-9]"
                placeholder="00:00"
                value={s.start_time}
                onChange={(e) => segment(i, "start_time", e.target.value)}
              />
            </Field>
            <Field label="До">
              <input
                required
                placeholder="24:00"
                pattern="(([01][0-9]|2[0-3]):[0-5][0-9]|24:00)"
                value={s.end_time}
                onChange={(e) => segment(i, "end_time", e.target.value)}
              />
            </Field>
          </div>
          <div className="four-fields">
            {[
              ["icr", "ICR, г/ЕД", "0.1", "200"],
              ["isf", "ISF", "0.1", "30"],
              ["target", "Цель", "3.9", "15"],
              ["correct_above", "Коррекция выше", "3.9", "30"],
            ].map(([key, label, min, max]) => (
              <Field label={label} key={key}>
                <input
                  required
                  type="number"
                  step="0.1"
                  min={min}
                  max={max}
                  value={s[key]}
                  onChange={(e) => segment(i, key, e.target.value)}
                />
              </Field>
            ))}
          </div>
          {data.segments.length > 1 && (
            <button
              type="button"
              className="text-button danger-text"
              onClick={() =>
                change(
                  "segments",
                  data.segments.filter((_: any, n: number) => n !== i),
                )
              }
            >
              Удалить период
            </button>
          )}
        </div>
      ))}
      <div className="profile-summary">
        <b>Проверьте перед сохранением</b>
        <p>
          DIA: {data.insulin_action_duration || "—"} ч · максимум:{" "}
          {data.max_bolus || "—"} ЕД · периодов: {data.segments.length} · шаг
          болюса: {decimal(data.bolus_increment)} ЕД · базальный:{" "}
          {decimal(data.basal_increment)} ЕД
        </p>
        {data.segments.map((s: any, i: number) => (
          <small key={i}>
            {s.start_time}–{s.end_time}: ICR {s.icr || "—"}, ISF {s.isf || "—"},
            цель {s.target || "—"}, коррекция выше {s.correct_above || "—"}
          </small>
        ))}
      </div>
      <label className="checkbox-row">
        <input
          type="checkbox"
          required
          checked={confirm}
          onChange={(e) => setConfirm(e.target.checked)}
        />
        <span>Я проверил(а) параметры и подтверждаю новую версию профиля.</span>
      </label>
      <ErrorBox message={error} />
      <Submit busy={busy}>Сохранить и подтвердить профиль</Submit>
    </form>
  );
}

export function FoodForm({ onSaved }: any) {
  const [data, setData] = useState<any>({
    name: "",
    brand: "",
    serving_name: "100 г",
    serving_weight: 100,
    carbs: "",
    protein: "",
    fat: "",
    calories: "",
    fiber: 0,
    sugar: 0,
  });
  const { busy, error, run } = useForm();
  return (
    <form
      className="form"
      onSubmit={(e) => {
        e.preventDefault();
        run(async () => {
          await post("/foods/custom", {
            ...data,
            ...Object.fromEntries(
              [
                "serving_weight",
                "carbs",
                "protein",
                "fat",
                "calories",
                "fiber",
                "sugar",
              ].map((k) => [k, Number(data[k])]),
            ),
          });
          await onSaved("Продукт добавлен в вашу базу");
        });
      }}
    >
      <Field label="Название">
        <input
          required
          maxLength={150}
          value={data.name}
          onChange={(e) => setData({ ...data, name: e.target.value })}
        />
      </Field>
      <Field label="Бренд · необязательно">
        <input
          maxLength={100}
          value={data.brand}
          onChange={(e) => setData({ ...data, brand: e.target.value })}
        />
      </Field>
      <p className="subtle-note">Пищевая ценность на 100 г продукта</p>
      <div className="two-fields">
        {[
          ["carbs", "Углеводы, г"],
          ["protein", "Белки, г"],
          ["fat", "Жиры, г"],
          ["calories", "Калории, ккал"],
          ["fiber", "Клетчатка, г"],
          ["sugar", "Сахар, г"],
        ].map(([k, label]) => (
          <Field label={label} key={k}>
            <input
              type="number"
              required
              min="0"
              max={k === "calories" ? 10000 : 1000}
              step="0.1"
              value={data[k]}
              onChange={(e) => setData({ ...data, [k]: e.target.value })}
            />
          </Field>
        ))}
      </div>
      <ErrorBox message={error} />
      <Submit busy={busy}>Создать продукт</Submit>
    </form>
  );
}
export function RecipeForm({ onSaved }: any) {
  const [items, setItems] = useState<any[]>([]),
    [name, setName] = useState(""),
    [weight, setWeight] = useState(""),
    [servings, setServings] = useState("1");
  const { busy, error, run } = useForm();
  const total = items.reduce((s, i) => s + i.carbs, 0);
  return (
    <form
      className="form"
      onSubmit={(e) => {
        e.preventDefault();
        run(async () => {
          if (!items.length) throw new Error("Добавьте ингредиенты");
          await post("/recipes", {
            name,
            ingredients: items.map(cleanItem),
            cooked_weight: Number(weight),
            servings: Number(servings),
          });
          await onSaved("Рецепт сохранён. Его можно найти в поиске еды.");
        });
      }}
    >
      <Field label="Название блюда">
        <input
          required
          placeholder="Например, сырники"
          maxLength={150}
          value={name}
          onChange={(e) => setName(e.target.value)}
        />
      </Field>
      <FoodPicker onPick={(f) => setItems([...items, makeItem(f)])} />
      <Ingredients items={items} setItems={setItems} />
      <div className="two-fields">
        <Field label="Вес готового блюда, г">
          <input
            required
            type="number"
            min="1"
            max="50000"
            value={weight}
            onChange={(e) => setWeight(e.target.value)}
          />
        </Field>
        <Field label="Число порций">
          <input
            required
            type="number"
            min="1"
            max="100"
            value={servings}
            onChange={(e) => setServings(e.target.value)}
          />
        </Field>
      </div>
      {Number(weight) > 0 && (
        <div className="info-box">
          Углеводы: {decimal((total / Number(weight)) * 100)} г на 100 г ·{" "}
          {decimal(total / Number(servings))} г на порцию
        </div>
      )}
      <ErrorBox message={error} />
      <Submit busy={busy}>Сохранить блюдо</Submit>
    </form>
  );
}
export function HealthImport({ onSaved }: any) {
  const [file, setFile] = useState<File | null>(null),
    [result, setResult] = useState<any>(null);
  const { busy, error, run } = useForm();
  return (
    <form
      className="form"
      onSubmit={(e) => {
        e.preventDefault();
        run(async () => {
          if (!file)
            throw new Error("Выберите ZIP или XML из Apple «Здоровья»");
          const data = new FormData();
          data.append("file", file);
          setResult(
            await api("/imports/apple-health", { method: "POST", body: data }),
          );
        });
      }}
    >
      <div className="health-intro">
        <span>
          <Heart size={30} />
        </span>
        <div>
          <b>Общая картина вашего дня</b>
          <p>Тренировки, длительность активности и дневная активная энергия.</p>
        </div>
      </div>
      <ol className="instructions">
        <li>Откройте «Здоровье» на iPhone.</li>
        <li>
          Нажмите на фото профиля и выберите «Экспортировать все данные о
          здоровье».
        </li>
        <li>Сохраните архив в «Файлы» и выберите его здесь.</li>
      </ol>
      <label className="upload-zone">
        <Upload size={27} />
        <b>{file?.name || "Выбрать файл"}</b>
        <small>ZIP или export.xml · до 20 МБ (XML в архиве — до 60 МБ)</small>
        <input
          type="file"
          accept=".zip,.xml,application/zip,text/xml"
          onChange={(e) => {
            setFile(e.target.files?.[0] || null);
            setResult(null);
          }}
        />
      </label>
      <div className="subtle-note">
        Веб-приложение получает только выбранный файл. Автоматический доступ к
        Apple Health потребует отдельного iOS-приложения. Повторные записи
        пропускаются.
      </div>
      <ErrorBox message={error} />
      {result ? (
        <>
          <div className="success-box">
            <Check size={20} />
            <div>
              Добавлено: {result.inserted} · пропущено: {result.skipped}
              <p>{result.message}</p>
            </div>
          </div>
          <button
            type="button"
            className="primary full"
            onClick={() =>
              onSaved("Активность из Apple «Здоровья» импортирована")
            }
          >
            Готово
          </button>
        </>
      ) : (
        <Submit busy={busy}>Импортировать активность</Submit>
      )}
    </form>
  );
}

export function OnboardingForm({ user, onSaved, onUser }: any) {
  const [step, setStep] = useState(0),
    [unit, setUnit] = useState(user.glucose_unit),
    [therapy, setTherapy] = useState("MDI"),
    [icr, setIcr] = useState(""),
    [isf, setIsf] = useState(""),
    [target, setTarget] = useState(""),
    [above, setAbove] = useState(""),
    [dia, setDia] = useState(""),
    [max, setMax] = useState(""),
    [cycle, setCycle] = useState(false),
    [cycleStart, setCycleStart] = useState(localDate()),
    [mascot, setMascot] = useState("cat"),
    [theme, setTheme] = useState("light"),
    [confirmed, setConfirmed] = useState(false);
  const { busy, error, run } = useForm();
  const titles = [
    "Добро пожаловать",
    "Единицы глюкозы",
    "Ваша терапия",
    "Углеводный коэффициент",
    "Чувствительность к инсулину",
    "Цель и порог коррекции",
    "Время действия и лимит",
    "Отслеживание цикла",
    "Маленький помощник",
    "Тема оформления",
    "Проверим параметры",
  ];
  return (
    <form
      className="form"
      onSubmit={(e) => {
        e.preventDefault();
        if (step < 10) {
          setStep(step + 1);
          return;
        }
        run(async () => {
          const u = await api("/users/me", {
            method: "PATCH",
            body: JSON.stringify({
              name: user.name,
              timezone: user.timezone,
              glucose_unit: unit,
              theme_id: theme,
              mascot_id: mascot,
            }),
          });
          await api("/profile", {
            method: "PUT",
            body: JSON.stringify({
              diabetes_type: "type1",
              insulin_therapy_type: therapy,
              rapid_insulin_name: "",
              basal_insulin_name: "",
              max_bolus: Number(max),
              insulin_action_duration: Number(dia),
              confirmed,
              segments: [
                {
                  start_time: "00:00",
                  end_time: "24:00",
                  icr: Number(icr),
                  isf: Number(isf),
                  target: Number(target),
                  correct_above: Number(above),
                },
              ],
            }),
          });
          if (cycle)
            await post("/cycle", { start_date: cycleStart, cycle_length: 28 });
          onUser(u);
          await onSaved("Ваш дневник настроен");
        });
      }}
    >
      <div className="onboarding-progress">
        <span style={{ width: ((step + 1) / 11) * 100 + "%" }} />
      </div>
      <div className="onboarding-title">
        <small>
          Шаг {Math.min(step + 1, 10)} из 10
          {step === 10 ? " · подтверждение" : ""}
        </small>
        <h3>{titles[step]}</h3>
      </div>
      {step === 0 && (
        <div className="onboarding-welcome">
          <img src="/mascot-cat.png" alt="Кот Персик" />
          <p>
            Это ваше спокойное место для наблюдений. Настроим дневник под вас —
            без оценок и соревнований.
          </p>
          <p className="subtle-note">
            Для коэффициентов терапии используйте значения, согласованные с
            вашим специалистом. Их можно изменить позже.
          </p>
        </div>
      )}
      {step === 1 && (
        <Field label="В каких единицах вы измеряете глюкозу?">
          <select value={unit} onChange={(e) => setUnit(e.target.value)}>
            <option value="mmol/L">ммоль/л</option>
            <option value="mg/dL">мг/дл</option>
          </select>
        </Field>
      )}
      {step === 2 && (
        <Field label="Как вы получаете инсулин?">
          <select value={therapy} onChange={(e) => setTherapy(e.target.value)}>
            <option value="MDI">Многократные инъекции (MDI)</option>
            <option value="PUMP">Инсулиновая помпа</option>
            <option value="OTHER">Другой вариант</option>
          </select>
        </Field>
      )}
      {step === 3 && (
        <Field label="ICR, г углеводов на 1 ЕД инсулина">
          <input
            autoFocus
            required
            min="0.1"
            max="200"
            step="0.1"
            type="number"
            value={icr}
            onChange={(e) => setIcr(e.target.value)}
          />
        </Field>
      )}
      {step === 4 && (
        <Field
          label="ISF, снижение глюкозы на 1 ЕД"
          hint="Введите значение в ммоль/л на ЕД, независимо от единиц дневника."
        >
          <input
            required
            min="0.1"
            max="30"
            step="0.1"
            type="number"
            value={isf}
            onChange={(e) => setIsf(e.target.value)}
          />
        </Field>
      )}
      {step === 5 && (
        <>
          <Field label="Целевая глюкоза, ммоль/л">
            <input
              required
              min="3.9"
              max="15"
              step="0.1"
              type="number"
              value={target}
              onChange={(e) => setTarget(e.target.value)}
            />
          </Field>
          <Field
            label="Коррекция только выше, ммоль/л"
            hint="Порог коррекции — отдельный параметр, он не ниже цели."
          >
            <input
              required
              min={Number(target) || 3.9}
              max="30"
              step="0.1"
              type="number"
              value={above}
              onChange={(e) => setAbove(e.target.value)}
            />
          </Field>
        </>
      )}
      {step === 6 && (
        <>
          <Field label="DIA, часов">
            <input
              required
              min="2"
              max="8"
              step="0.5"
              type="number"
              value={dia}
              onChange={(e) => setDia(e.target.value)}
            />
          </Field>
          <Field label="Максимальный болюс, ЕД">
            <input
              required
              min="0.1"
              max="50"
              step="0.1"
              type="number"
              value={max}
              onChange={(e) => setMax(e.target.value)}
            />
          </Field>
        </>
      )}
      {step === 7 && (
        <>
          <label className="checkbox-row">
            <input
              type="checkbox"
              checked={cycle}
              onChange={(e) => setCycle(e.target.checked)}
            />
            Хочу отслеживать менструальный цикл
          </label>
          {cycle && (
            <Field
              label="Начало последней менструации"
              hint="Начальная длина цикла — 28 дней; её можно уточнить на экране цикла."
            >
              <input
                required
                type="date"
                max={localDate()}
                value={cycleStart}
                onChange={(e) => setCycleStart(e.target.value)}
              />
            </Field>
          )}
        </>
      )}
      {step === 8 && (
        <Field label="Кто будет рядом?">
          <select value={mascot} onChange={(e) => setMascot(e.target.value)}>
            {[
              ["cat", "🐱 Кот"],
              ["pig", "🐷 Поросёнок"],
              ["dinosaur", "🦕 Динозавр"],
              ["rabbit", "🐰 Кролик"],
              ["otter", "🦦 Выдра"],
              ["panda", "🐼 Панда"],
            ].map(([k, l]) => (
              <option key={k} value={k}>
                {l}
              </option>
            ))}
          </select>
        </Field>
      )}
      {step === 9 && (
        <Field label="Выберите тему">
          <select value={theme} onChange={(e) => setTheme(e.target.value)}>
            {[
              ["light", "Minimal Light"],
              ["dark", "Minimal Dark"],
              ["cat", "Cat Café"],
              ["pink", "Pink Pastel"],
              ["dino", "Dino"],
              ["oled", "OLED Black"],
            ].map(([k, l]) => (
              <option key={k} value={k}>
                {l}
              </option>
            ))}
          </select>
        </Field>
      )}
      {step === 10 && (
        <>
          <div className="profile-summary">
            <p>
              Терапия: {therapy} · единицы дневника: {unit}
            </p>
            <p>
              ICR: {icr} г/ЕД · ISF: {isf} ммоль/л/ЕД
            </p>
            <p>
              Цель: {target} · коррекция выше: {above} ммоль/л
            </p>
            <p>
              DIA: {dia} ч · максимальный болюс: {max} ЕД
            </p>
            <p>
              Период: 00:00–24:00. Временные сегменты можно добавить в профиле.
            </p>
          </div>
          <label className="checkbox-row">
            <input
              required
              type="checkbox"
              checked={confirmed}
              onChange={(e) => setConfirmed(e.target.checked)}
            />
            Я проверил(а) и подтверждаю параметры терапии.
          </label>
          <p className="subtle-note">
            Расчёт использует подтверждённые параметры вашего профиля.
          </p>
        </>
      )}
      <ErrorBox message={error} />
      <div className="form-actions">
        {step > 0 && (
          <button
            type="button"
            className="secondary"
            disabled={busy}
            onClick={() => setStep(step - 1)}
          >
            Назад
          </button>
        )}
        <Submit busy={busy}>
          {step === 10 ? "Подтвердить и открыть дневник" : "Продолжить"}
        </Submit>
      </div>
    </form>
  );
}
