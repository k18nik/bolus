"use client";
import { useEffect, useRef, useState } from "react";
import {
  Droplet,
  Utensils,
  Syringe,
  Activity,
  Moon,
  FileText,
  Calculator,
  Check,
} from "lucide-react";
import { decimal, localDate, newId } from "@/services/api";
import { saveOrQueue } from "@/services/offline";
import { Field, ErrorBox } from "./ui";
import {
  FoodPicker,
  Ingredients,
  makeItem,
  cleanItem,
  BolusForm,
  ProfileForm,
} from "./forms";
import { AssistantView, AISettingsForm } from "./ai-assistant";

const nowLocal = () => {
  const d = new Date();
  return new Date(d.getTime() - d.getTimezoneOffset() * 60000)
    .toISOString()
    .slice(0, 16);
};
const sections = [
  ["glucose", "Глюкоза", Droplet],
  ["meal", "Еда", Utensils],
  ["insulin", "Инсулин", Syringe],
  ["activity", "Активность", Activity],
  ["cycle", "Цикл", Moon],
  ["note", "Заметка", FileText],
  ["bolus", "Болюс", Calculator],
] as const;

export function UnifiedEntryForm({
  user,
  profile,
  latest,
  offline,
  clinicalUseEnabled,
  initialSection = "glucose",
  onRefresh,
  onExplain,
}: any) {
  const [time, setTime] = useState(nowLocal),
    [glucose, setGlucose] = useState(""),
    [items, setItems] = useState<any[]>([]),
    [carbs, setCarbs] = useState(""),
    [mealName, setMealName] = useState("Приём пищи"),
    [rapid, setRapid] = useState(""),
    [basal, setBasal] = useState(""),
    [activity, setActivity] = useState(""),
    [minutes, setMinutes] = useState(""),
    [intensity, setIntensity] = useState("moderate"),
    [cycleStart, setCycleStart] = useState(""),
    [cycleLength, setCycleLength] = useState("28"),
    [note, setNote] = useState(""),
    [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [message, setMessage] = useState(""),
    [revision, setRevision] = useState(0),
    [showProfile, setShowProfile] = useState(false);
  const container = useRef<HTMLDivElement>(null),
    submission = useRef<{ hash: string; id: string } | null>(null);
  const [aiCalculation, setAiCalculation] = useState<string | null>(null),
    [aiSettings, setAiSettings] = useState(false),
    [aiRefresh, setAiRefresh] = useState(0);
  const scrollTo = (id: string) =>
    container.current
      ?.querySelector("#entry-" + id)
      ?.scrollIntoView({ behavior: "smooth", block: "start" });
  useEffect(() => {
    if (initialSection !== "glucose") scrollTo(initialSection);
  }, []);
  const hasInput = Boolean(
    glucose ||
    items.length ||
    carbs ||
    rapid ||
    basal ||
    minutes ||
    activity ||
    cycleStart ||
    note.trim(),
  );
  const totalCarbs =
    items.reduce((sum, i) => sum + i.carbs, 0) + (Number(carbs) || 0);
  const clear = () => {
    setGlucose("");
    setItems([]);
    setCarbs("");
    setRapid("");
    setBasal("");
    setActivity("");
    setMinutes("");
    setCycleStart("");
    setNote("");
    submission.current = null;
    setRevision((v) => v + 1);
  };
  async function save(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError("");
    setMessage("");
    try {
      if (!hasInput)
        throw new Error(
          "Заполните хотя бы один раздел — например, только глюкозу.",
        );
      if ((activity && !minutes) || (minutes && !activity.trim()))
        throw new Error("Для активности укажите название и длительность.");
      const at = new Date(time).toISOString(),
        data: any = { insulin: [] };
      if (glucose)
        data.glucose = {
          value: Number(glucose),
          unit: user.glucose_unit,
          measured_at: at,
          client_id: "glucose",
        };
      if (items.length || carbs) {
        const mealItems = items.map(cleanItem);
        if (carbs)
          mealItems.push({
            name_snapshot: "Углеводы, введённые вручную",
            grams: 100,
            amount: 100,
            unit: "g",
            carbs: Number(carbs),
            protein: 0,
            fat: 0,
            calories: 0,
          });
        data.meal = {
          name: mealName,
          meal_type: "snack",
          eaten_at: at,
          items: mealItems,
          client_id: "meal",
        };
      }
      for (const [value, type] of [
        [rapid, "rapid"],
        [basal, "basal"],
      ])
        if (value)
          data.insulin.push({
            units: Number(value),
            insulin_type: type,
            insulin_name:
              profile?.[
                type === "rapid" ? "rapid_insulin_name" : "basal_insulin_name"
              ] || "",
            purpose: type === "basal" ? "basal" : "manual",
            administered_at: at,
            client_id: type,
          });
      if (minutes)
        data.activity = {
          name: activity.trim(),
          duration_minutes: Number(minutes),
          intensity,
          occurred_at: at,
          client_id: "activity",
        };
      if (cycleStart)
        data.cycle = {
          start_date: cycleStart,
          cycle_length: Number(cycleLength),
        };
      if (note.trim())
        data.note = { note: note.trim(), occurred_at: at, client_id: "note" };
      const hash = JSON.stringify(data);
      if (submission.current?.hash !== hash)
        submission.current = { hash, id: newId() };
      const result = await saveOrQueue(user.id, "/diary/batch", {
        ...data,
        client_id: submission.current!.id,
      });
      clear();
      setMessage(
        result.queued
          ? "Сохранено на устройстве. Отправим после подключения."
          : `Сохранено записей: ${result.count}`,
      );
      await onRefresh();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  const valueForBolus =
    glucose ||
    (latest
      ? String(
          Math.round(
            latest.data.value_mmol *
              (user.glucose_unit === "mg/dL" ? 18 : 1) *
              10,
          ) / 10,
        )
      : "");
  const measuredForBolus = glucose
    ? time
    : latest
      ? new Date(
          new Date(latest.occurred_at).getTime() -
            new Date().getTimezoneOffset() * 60000,
        )
          .toISOString()
          .slice(0, 16)
      : time;
  return (
    <div className="unified-entry" ref={container}>
      <p className="muted">
        Заполните только нужное. Все разделы находятся на этой странице.
      </p>
      <nav className="entry-shortcuts" aria-label="Разделы записи">
        {sections.map(([id, label, Icon]) => (
          <button key={id} type="button" onClick={() => scrollTo(id)}>
            <Icon size={16} />
            {label}
          </button>
        ))}
      </nav>
      <div className="entry-savebar">
        <button
          form="entry-form"
          type="submit"
          className="primary full"
          disabled={busy || !hasInput}
        >
          {busy ? "Сохраняем…" : "Сохранить заполненное"}
        </button>
      </div>
      <ErrorBox message={error} />
      {message && (
        <div className="success-box" role="status">
          <Check size={18} />
          {message}
        </div>
      )}
      <form id="entry-form" onSubmit={save} className="form">
        <Field label="Дата и время записи" hint="В часовом поясе устройства">
          <input
            required
            type="datetime-local"
            value={time}
            max={nowLocal()}
            onChange={(e) => setTime(e.target.value)}
          />
        </Field>
        <section id="entry-glucose" className="entry-section">
          <h3>
            <Droplet size={20} />
            Глюкоза
          </h3>
          <Field
            label={
              user.glucose_unit === "mg/dL"
                ? "Глюкоза, мг/дл"
                : "Глюкоза, ммоль/л"
            }
          >
            <input
              className="large-input"
              type="number"
              inputMode="decimal"
              min={user.glucose_unit === "mg/dL" ? 9 : 0.5}
              max={user.glucose_unit === "mg/dL" ? 990 : 55}
              step="0.1"
              placeholder="Можно оставить пустым"
              value={glucose}
              onChange={(e) => setGlucose(e.target.value)}
            />
          </Field>
        </section>
        <section id="entry-meal" className="entry-section">
          <h3>
            <Utensils size={20} />
            Еда
          </h3>
          <Field label="Название приёма пищи">
            <input
              value={mealName}
              maxLength={150}
              onChange={(e) => setMealName(e.target.value)}
            />
          </Field>
          <FoodPicker onPick={(f) => setItems((v) => [...v, makeItem(f)])} />
          <Ingredients items={items} setItems={setItems} />
          <Field
            label="Углеводы вручную, г"
            hint="Добавляются к выбранным продуктам. Остальные нутриенты для этой строки не указаны."
          >
            <input
              type="number"
              inputMode="decimal"
              min="0"
              max="500"
              step="0.1"
              value={carbs}
              onChange={(e) => setCarbs(e.target.value)}
              placeholder="Необязательно"
            />
          </Field>
          <div className="nutrition-total">
            <div>
              <span>Всего углеводов</span>
              <b>{decimal(totalCarbs)} г</b>
            </div>
          </div>
        </section>
        <section id="entry-insulin" className="entry-section">
          <h3>
            <Syringe size={20} />
            Фактически введённый инсулин
          </h3>
          <p className="subtle-note">
            Сохранённый быстрый инсулин участвует в IOB. Базальный учитывается
            отдельно.
          </p>
          <div className="two-fields">
            <Field
              label={`${profile?.rapid_insulin_name || "Быстрый инсулин"}, ЕД`}
              hint={`Шаг ${decimal(profile?.bolus_increment ?? 1)} ЕД`}
            >
              <input
                type="number"
                min={profile?.bolus_increment ?? 1}
                max="200"
                step={profile?.bolus_increment ?? 1}
                value={rapid}
                onChange={(e) => setRapid(e.target.value)}
                placeholder="Необязательно"
              />
            </Field>
            <Field
              label={`${profile?.basal_insulin_name || "Базальный инсулин"}, ЕД`}
              hint={`Шаг ${decimal(profile?.basal_increment ?? 1)} ЕД`}
            >
              <input
                type="number"
                min={profile?.basal_increment ?? 1}
                max="200"
                step={profile?.basal_increment ?? 1}
                value={basal}
                onChange={(e) => setBasal(e.target.value)}
                placeholder="Необязательно"
              />
            </Field>
          </div>
        </section>
        <section id="entry-activity" className="entry-section">
          <h3>
            <Activity size={20} />
            Активность
          </h3>
          <Field label="Название активности">
            <input
              maxLength={100}
              value={activity}
              onChange={(e) => setActivity(e.target.value)}
              placeholder="Например, прогулка"
            />
          </Field>
          <div className="two-fields">
            <Field label="Длительность, мин">
              <input
                type="number"
                min="1"
                max="1440"
                value={minutes}
                onChange={(e) => setMinutes(e.target.value)}
                placeholder="Необязательно"
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
        </section>
        <section id="entry-cycle" className="entry-section">
          <h3>
            <Moon size={20} />
            Цикл
          </h3>
          <div className="two-fields">
            <Field label="Первый день менструации">
              <input
                type="date"
                value={cycleStart}
                max={localDate(new Date(), user.timezone)}
                onChange={(e) => setCycleStart(e.target.value)}
              />
            </Field>
            <Field label="Обычная длина цикла, дней">
              <input
                type="number"
                min="15"
                max="90"
                required={!!cycleStart}
                value={cycleLength}
                onChange={(e) => setCycleLength(e.target.value)}
              />
            </Field>
          </div>
        </section>
        <section id="entry-note" className="entry-section">
          <h3>
            <FileText size={20} />
            Заметка
          </h3>
          <Field label="Что хочется отметить?">
            <textarea
              rows={3}
              maxLength={2000}
              value={note}
              onChange={(e) => setNote(e.target.value)}
              placeholder="Самочувствие, сон или любые наблюдения"
            />
          </Field>
        </section>
      </form>
      <section id="entry-bolus" className="entry-section">
        <h3>
          <Calculator size={20} />
          Рассчитать болюс
        </h3>
        {rapid || basal ? (
          <div className="info-box">
            Сначала сохраните введённый инсулин кнопкой «Сохранить заполненное»,
            чтобы расчёт учитывал актуальный IOB.
          </div>
        ) : (
          <BolusForm
            user={user}
            profile={profile}
            latest={latest}
            offline={offline}
            clinicalUseEnabled={clinicalUseEnabled}
            draft={{
              glucose: valueForBolus,
              carbs: String(totalCarbs),
              measured: measuredForBolus,
              revision,
            }}
            onProfile={() => setShowProfile(true)}
            onExplain={setAiCalculation}
            onSaved={async (message: string) => {
              setMessage(message);
              setRevision((v) => v + 1);
              await onRefresh();
            }}
          />
        )}
        {showProfile && (
          <ProfileForm
            profile={profile}
            onSaved={async () => {
              await onRefresh();
              setShowProfile(false);
            }}
          />
        )}
      </section>
      {aiCalculation && (
        <section className="entry-section">
          <AssistantView
            key={aiRefresh}
            calculationId={aiCalculation}
            onSettings={() => setAiSettings((v) => !v)}
            onClearCalculation={() => setAiCalculation(null)}
          />
          {aiSettings && (
            <AISettingsForm
              onSaved={() => {
                setAiRefresh((v) => v + 1);
              }}
            />
          )}
        </section>
      )}
    </div>
  );
}
