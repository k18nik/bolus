"use client";
import { useEffect, useState } from "react";
import {
  Plus,
  Search,
  Download,
  FileText,
  Trash2,
  Heart,
  Sparkles,
  ChevronRight,
  ShieldCheck,
  Settings,
  LogOut,
  Moon,
  Utensils,
  Activity,
  Check,
  ExternalLink,
  LoaderCircle,
  Database,
  Calendar,
  Palette,
  Link,
} from "lucide-react";
import { api, post, decimal, localDate } from "@/services/api";
import { GlucoseChart } from "./chart";
import { Empty, ErrorBox, Field, Submit, Modal } from "./ui";
import { foodUnit } from "./forms";

export function AnalyticsView({
  user,
  refreshKey,
  onAssistant,
  onHealth,
}: any) {
  const [days, setDays] = useState(7),
    [data, setData] = useState<any>(null),
    [error, setError] = useState(""),
    [loading, setLoading] = useState(true);
  useEffect(() => {
    let active = true;
    setLoading(true);
    api("/analytics?days=" + days)
      .then((d) => {
        if (active) {
          setData(d);
          setError("");
        }
      })
      .catch((e) => setError(e.message))
      .finally(() => {
        if (active) setLoading(false);
      });
    return () => {
      active = false;
    };
  }, [days, refreshKey]);
  const m = data?.metrics || {};
  const factor = user.glucose_unit === "mg/dL" ? 18 : 1;
  return (
    <div className="view-stack">
      <div className="view-toolbar">
        <div className="segmented large">
          {[1, 7, 14, 30, 90].map((n) => (
            <button
              key={n}
              className={n === days ? "selected" : ""}
              onClick={() => setDays(n)}
            >
              {n === 1 ? "24 ч" : n + " дней"}
            </button>
          ))}
        </div>
        <button className="secondary" onClick={onAssistant}>
          <Sparkles size={17} />
          Ассистент
        </button>
      </div>
      <ErrorBox message={error} />
      {loading ? (
        <div className="loading-state card">Собираем ваши наблюдения…</div>
      ) : (
        <>
          <div className="analytics-metrics">
            {[
              [
                "Средняя глюкоза",
                m.mean_glucose ? decimal(m.mean_glucose * factor) : "—",
                user.glucose_unit === "mg/dL" ? "мг/дл" : "ммоль/л",
              ],
              ["В диапазоне", decimal(m.tir), "% измерений"],
              ["Инсулин в сутки", decimal(m.daily_insulin), "ЕД"],
              ["Углеводы в сутки", decimal(m.carbs_per_day), "г"],
            ].map(([label, v, unit]) => (
              <div className="card stat-card" key={label}>
                <span>{label}</span>
                <b>
                  {v}
                  <small>{unit}</small>
                </b>
              </div>
            ))}
          </div>
          <div className="card analytics-chart">
            <div className="card-heading">
              <h2>История глюкозы</h2>
              <span className="muted">{m.sample_size || 0} измерений</span>
            </div>
            <GlucoseChart
              entries={data?.entries}
              unit={user.glucose_unit}
              timezone={user.timezone}
            />
            <p className="chart-disclaimer">
              Проценты рассчитаны по записанным измерениям. При ручном вводе это
              не оценка времени CGM в диапазоне.
            </p>
          </div>
          <div className="two-columns">
            <section className="card padded">
              <h2>Распределение глюкозы</h2>
              <div className="range-bar">
                <span
                  style={{ width: (m.tbr || 0) + "%", background: "#dfa59f" }}
                />
                <span
                  style={{ width: (m.tir || 0) + "%", background: "#6daf93" }}
                />
                <span
                  style={{ width: (m.tar || 0) + "%", background: "#e2be78" }}
                />
              </div>
              {[
                ["Ниже диапазона", m.tbr, "#dfa59f"],
                ["В диапазоне", m.tir, "#6daf93"],
                ["Выше диапазона", m.tar, "#e2be78"],
              ].map(([l, v, c]) => (
                <div className="data-row" key={String(l)}>
                  <span>
                    <i style={{ background: String(c) }} />
                    {l}
                  </span>
                  <b>{decimal(v as number)}%</b>
                </div>
              ))}
              <div className="data-row">
                <span>Коэффициент вариации</span>
                <b>{decimal(m.coefficient_of_variation)}%</b>
              </div>
              <div className="data-row">
                <span>Медиана</span>
                <b>
                  {decimal(m.median_glucose ? m.median_glucose * factor : null)}
                </b>
              </div>
              <div className="data-row">
                <span>Минимум / максимум</span>
                <b>
                  {decimal(m.min ? m.min * factor : null)} /{" "}
                  {decimal(m.max ? m.max * factor : null)}
                </b>
              </div>
              <div className="data-row">
                <span>Стандартное отклонение</span>
                <b>
                  {decimal(
                    m.standard_deviation !== null
                      ? m.standard_deviation * factor
                      : null,
                  )}
                </b>
              </div>
            </section>
            <section className="card padded">
              <h2>Инсулин и питание</h2>
              {[
                ["Болюсный в сутки", decimal(m.bolus_insulin) + " ЕД"],
                ["Базальный в сутки", decimal(m.basal_insulin) + " ЕД"],
                ["Коррекций в сутки", decimal(m.corrections_per_day)],
                ["Энергия в сутки", decimal(m.calories_per_day, 0) + " ккал"],
                [
                  "Активность за период",
                  (data?.activity_minutes || 0) + " мин",
                ],
              ].map(([l, v]) => (
                <div className="data-row" key={l}>
                  <span>{l}</span>
                  <b>{v}</b>
                </div>
              ))}
              <button className="health-card inset" onClick={onHealth}>
                <Heart size={21} />
                <div>
                  <b>Apple «Здоровье»</b>
                  <small>Импортировать тренировки</small>
                </div>
                <ChevronRight size={17} />
              </button>
            </section>
          </div>
          <section className="card padded">
            <div className="section-title">
              <h2>Глюкоза рядом с тренировками</h2>
              <Activity size={20} />
            </div>
            <p className="muted">
              Последнее измерение за час до начала и первое в течение двух часов
              после окончания. Наблюдаемая связь не означает причинность.
            </p>
            {data?.activity_response?.length ? (
              <div className="table-scroll">
                <table>
                  <thead>
                    <tr>
                      <th>Активность</th>
                      <th>До</th>
                      <th>После</th>
                      <th>Изменение</th>
                    </tr>
                  </thead>
                  <tbody>
                    {data.activity_response.slice(-12).map((r: any) => (
                      <tr key={r.activity_id}>
                        <td>
                          {r.name}
                          <small>
                            {r.source === "apple_health"
                              ? "Apple «Здоровье»"
                              : "Дневник"}
                          </small>
                        </td>
                        <td>{decimal(r.before * factor)}</td>
                        <td>{decimal(r.after * factor)}</td>
                        <td>
                          {r.change > 0 ? "+" : ""}
                          {decimal(r.change * factor)}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            ) : (
              <p className="empty-inline">
                Пока нет тренировок с измерениями до и после. Импортируйте
                активность или добавьте её вручную.
              </p>
            )}
          </section>
          <section className="card padded">
            <div className="section-title">
              <h2>По дням</h2>
              <Calendar size={20} />
            </div>
            <div className="table-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Дата</th>
                    <th>Средняя</th>
                    <th>В диапазоне</th>
                    <th>Инсулин</th>
                    <th>Углеводы</th>
                    <th>Активность</th>
                  </tr>
                </thead>
                <tbody>
                  {data?.daily
                    ?.slice()
                    .reverse()
                    .map((r: any) => (
                      <tr key={r.date}>
                        <td>
                          {new Date(r.date + "T12:00:00").toLocaleDateString(
                            "ru-RU",
                            { day: "numeric", month: "short" },
                          )}
                        </td>
                        <td>
                          {decimal(
                            r.mean_glucose ? r.mean_glucose * factor : null,
                          )}
                        </td>
                        <td>{decimal(r.tir)}%</td>
                        <td>{decimal(r.daily_insulin)} ЕД</td>
                        <td>{decimal(r.carbs_per_day)} г</td>
                        <td>{r.activity_minutes} мин</td>
                      </tr>
                    ))}
                </tbody>
              </table>
            </div>
          </section>
        </>
      )}
    </div>
  );
}

const reportNames: any = {
  doctor: "Отчёт для врача",
  summary: "Общая сводка",
  glucose: "Глюкоза",
  insulin: "Инсулин",
  nutrition: "Питание",
  cycle: "Менструальный цикл",
  raw: "Исходные данные",
};
export function ReportsView({ user, showToast }: any) {
  const [type, setType] = useState("doctor"),
    [format, setFormat] = useState("pdf"),
    [days, setDays] = useState(30),
    [dateFrom, setDateFrom] = useState(""),
    [dateTo, setDateTo] = useState(localDate(new Date(), user.timezone)),
    [graphs, setGraphs] = useState(true),
    [nutrition, setNutrition] = useState(true),
    [cycle, setCycle] = useState(true),
    [jobs, setJobs] = useState<any[]>([]),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  const load = () =>
    api("/reports")
      .then(setJobs)
      .catch((e) => setError(e.message));
  useEffect(() => {
    load();
  }, []);
  useEffect(() => {
    if (!jobs.some((j) => ["queued", "processing"].includes(j.status))) return;
    const id = setInterval(load, 2000);
    return () => clearInterval(id);
  }, [jobs]);
  return (
    <div className="report-layout">
      <section className="card padded">
        <div className="section-title">
          <h2>Создать отчёт</h2>
          <FileText size={20} />
        </div>
        <form
          className="form"
          onSubmit={async (e) => {
            e.preventDefault();
            setBusy(true);
            setError("");
            try {
              const end =
                days === 0 ? dateTo : localDate(new Date(), user.timezone);
              const d = new Date(end + "T12:00:00");
              d.setDate(d.getDate() - Math.max(days - 1, 0));
              const start = days === 0 ? dateFrom : localDate(d, user.timezone);
              await post("/reports", {
                type,
                format,
                date_from: start,
                date_to: end,
                include_graphs: graphs,
                include_nutrition: nutrition,
                include_cycle: cycle,
                include_ai: false,
              });
              await load();
              showToast("Отчёт поставлен в очередь");
            } catch (e) {
              setError((e as Error).message);
            } finally {
              setBusy(false);
            }
          }}
        >
          <Field label="Тип отчёта">
            <select value={type} onChange={(e) => setType(e.target.value)}>
              {Object.entries(reportNames)
                .filter(([key]) => key !== "personalization")
                .map(([id, n]) => (
                  <option key={id} value={id}>
                    {String(n)}
                  </option>
                ))}
            </select>
          </Field>
          <Field label="Период">
            <select
              value={days}
              onChange={(e) => setDays(Number(e.target.value))}
            >
              {[7, 14, 30, 90].map((n) => (
                <option key={n} value={n}>
                  Последние {n} дней
                </option>
              ))}
              <option value={0}>Выбрать даты</option>
            </select>
          </Field>
          {days === 0 && (
            <div className="two-fields">
              <Field label="С">
                <input
                  required
                  type="date"
                  value={dateFrom}
                  max={dateTo}
                  onChange={(e) => setDateFrom(e.target.value)}
                />
              </Field>
              <Field label="По">
                <input
                  required
                  type="date"
                  value={dateTo}
                  min={dateFrom}
                  onChange={(e) => setDateTo(e.target.value)}
                />
              </Field>
            </div>
          )}
          <Field label="Формат">
            <select value={format} onChange={(e) => setFormat(e.target.value)}>
              <option value="pdf">PDF · для чтения и печати</option>
              <option value="xlsx">Excel · все таблицы</option>
              <option value="csv">CSV · архив таблиц</option>
              <option value="json">JSON · полная резервная копия</option>
            </select>
          </Field>
          {format === "json" ? (
            <div className="info-box">
              JSON содержит все данные аккаунта за всё время, независимо от
              выбранного периода.
            </div>
          ) : (
            <div className="report-options">
              {format === "pdf" && (
                <label className="checkbox-row">
                  <input
                    type="checkbox"
                    checked={graphs}
                    onChange={(e) => setGraphs(e.target.checked)}
                  />
                  Включить графики
                </label>
              )}
              <label className="checkbox-row">
                <input
                  type="checkbox"
                  checked={nutrition}
                  onChange={(e) => setNutrition(e.target.checked)}
                />
                Включить питание
              </label>
              <label className="checkbox-row">
                <input
                  type="checkbox"
                  checked={cycle}
                  onChange={(e) => setCycle(e.target.checked)}
                />
                Включить цикл
              </label>
            </div>
          )}
          <ErrorBox message={error} />
          <Submit busy={busy}>Создать отчёт</Submit>
        </form>
      </section>
      <section className="card padded">
        <div className="section-title">
          <h2>Мои отчёты</h2>
          <Download size={20} />
        </div>
        {jobs.length ? (
          <div className="report-list">
            {jobs.map((j) => (
              <article key={j.id} className="report-item">
                <span className="report-file-icon">
                  <FileText size={23} />
                  <small>{j.format.toUpperCase()}</small>
                </span>
                <div>
                  <b>{reportNames[j.type]}</b>
                  <small>
                    {j.date_from} — {j.date_to}
                  </small>
                  <small>
                    {j.status === "completed"
                      ? "Готов · хранится 7 дней"
                      : j.status === "failed"
                        ? j.error
                        : j.status === "queued"
                          ? "В очереди…"
                          : "Создаём…"}
                  </small>
                </div>
                <div className="report-item-actions">
                  {j.status === "completed" && (
                    <a
                      className="icon-button"
                      aria-label="Скачать отчёт"
                      href={"/api/reports/" + j.id + "/download"}
                      download
                    >
                      <Download size={19} />
                    </a>
                  )}
                  {["queued", "processing"].includes(j.status) && (
                    <LoaderCircle className="spin" size={18} />
                  )}
                  <button
                    className="icon-button"
                    aria-label="Удалить отчёт"
                    onClick={async () => {
                      try {
                        await api("/reports/" + j.id, { method: "DELETE" });
                        await load();
                      } catch (e) {
                        setError((e as Error).message);
                      }
                    }}
                  >
                    <Trash2 size={17} />
                  </button>
                </div>
              </article>
            ))}
          </div>
        ) : (
          <Empty
            title="Ваш первый отчёт впереди"
            text="Выберите период и формат. Готовый файл появится здесь."
          />
        )}
        <div className="direct-exports">
          <h3>Отдельные таблицы CSV</h3>
          {[
            ["glucose", "Глюкоза"],
            ["insulin", "Инсулин"],
            ["meals", "Питание"],
            ["bolus", "Расчёты"],
            ["cycle", "Цикл"],
          ].map(([id, name]) => (
            <a key={id} href={"/api/export/" + id + "?days=30"} download>
              <Download size={14} />
              {name}
            </a>
          ))}
          <p className="subtle-note">Последние 30 дней · UTF-8 · ISO 8601</p>
        </div>
      </section>
    </div>
  );
}

export function FoodsView({ onAdd, onCustom, onRecipe, refreshKey }: any) {
  const [query, setQuery] = useState(""),
    [foods, setFoods] = useState<any[]>([]),
    [error, setError] = useState(""),
    [loading, setLoading] = useState(false),
    [selected, setSelected] = useState<any>(null),
    [favorites, setFavorites] = useState<any[]>([]),
    [warnings, setWarnings] = useState<string[]>([]);
  useEffect(() => {
    api("/foods/favorites")
      .then(setFavorites)
      .catch(() => {});
  }, [refreshKey]);
  useEffect(() => {
    let active = true;
    const id = setTimeout(() => {
      setLoading(true);
      api("/foods/search?q=" + encodeURIComponent(query))
        .then((r) => {
          if (active) {
            setFoods(r.foods);
            setWarnings(r.warnings || []);
            setError("");
          }
        })
        .catch((e) => {
          if (active) {
            setFoods([]);
            setWarnings([]);
            setError(e.message);
          }
        })
        .finally(() => {
          if (active) setLoading(false);
        });
    }, 400);
    return () => {
      active = false;
      clearTimeout(id);
    };
  }, [query, refreshKey]);
  return (
    <div className="view-stack">
      <div className="view-toolbar">
        <div className="search-input grow">
          <Search size={18} />
          <input
            aria-label="Найти продукт"
            placeholder="Найти продукт или своё блюдо"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </div>
        <button className="secondary" onClick={onCustom}>
          <Plus size={17} />
          Продукт
        </button>
        <button className="primary" onClick={onRecipe}>
          <Utensils size={17} />
          Моё блюдо
        </button>
      </div>
      <ErrorBox message={error} />
      <div className="food-catalog">
        {loading ? (
          <div className="loading-state">Ищем продукты…</div>
        ) : (
          foods.map((f) => (
            <button
              className="card food-card"
              key={f.provider + f.external_id}
              onClick={() => setSelected(f)}
            >
              <span className="food-symbol">
                <Utensils size={24} />
              </span>
              <div>
                <h3>{f.name}</h3>
                <p>
                  {f.brand || f.provider} · на {f.serving_weight || 100}{" "}
                  {foodUnit(f)}
                </p>
                <span>
                  {decimal(f.carbs)} г углеводов <i /> {decimal(f.calories, 0)}{" "}
                  ккал
                </span>
              </div>
              <ChevronRight size={16} />
            </button>
          ))
        )}
      </div>
      {!loading && !foods.length && (
        <Empty
          title={
            query.trim().length < 2 ? "Что будем искать?" : "Не нашли продукт?"
          }
          text={
            query.trim().length < 2
              ? "Введите от двух букв: название продукта или бренд."
              : "Добавьте состав с упаковки в свою базу."
          }
        />
      )}
      <p className="subtle-note">
        Поиск в YAZIO и ваших продуктах. Вход в YAZIO не нужен. Состав указан на
        100 г или 100 мл — сверяйте его с упаковкой.
      </p>
      {warnings.map((warning) => (
        <p key={warning} className="subtle-note" role="status">
          {warning}
        </p>
      ))}
      {selected && (
        <Modal title={selected.name} onClose={() => setSelected(null)}>
          <p className="muted">
            На {selected.serving_weight || 100} {foodUnit(selected)} ·{" "}
            {selected.provider === "yazio" ? "YAZIO" : selected.provider}
          </p>
          {[
            ["Углеводы", "carbs", "г"],
            ["Белки", "protein", "г"],
            ["Жиры", "fat", "г"],
            ["Энергия", "calories", "ккал"],
            ["Клетчатка", "fiber", "г"],
            ["Сахар", "sugar", "г"],
          ].map(([label, key, unit]) => (
            <div className="data-row" key={key}>
              <span>{label}</span>
              <b>
                {selected[key] == null
                  ? "Не указано"
                  : `${decimal(selected[key])} ${unit}`}
              </b>
            </div>
          ))}
          <button
            className="secondary full"
            onClick={async () => {
              try {
                const existing = favorites.find(
                  (f) =>
                    f.provider === selected.provider &&
                    f.external_id === selected.external_id,
                );
                if (existing) {
                  await api("/foods/favorites/" + existing.favorite_id, {
                    method: "DELETE",
                  });
                } else {
                  const f = selected;
                  await post("/foods/favorites", {
                    name: f.name,
                    brand: f.brand || "",
                    serving_name: f.serving_name || f.serving || "100 г",
                    serving_weight: f.serving_weight || 100,
                    external_id: f.external_id,
                    provider: f.provider,
                    base_unit: f.base_unit || "g",
                    ...Object.fromEntries(
                      [
                        "carbs",
                        "protein",
                        "fat",
                        "calories",
                        "fiber",
                        "sugar",
                      ].map((k) => [
                        k,
                        (k === "fiber" || k === "sugar") && f[k] == null
                          ? null
                          : f[k] || 0,
                      ]),
                    ),
                  });
                }
                setFavorites(await api("/foods/favorites"));
              } catch (e) {
                setError((e as Error).message);
              }
            }}
          >
            <Heart size={16} />
            {favorites.some(
              (f) =>
                f.provider === selected.provider &&
                f.external_id === selected.external_id,
            )
              ? "Убрать из избранного"
              : "В избранное"}
          </button>
          <button
            className="primary full"
            style={{ marginTop: 12 }}
            onClick={() => {
              setSelected(null);
              onAdd();
            }}
          >
            Добавить приём пищи
          </button>
        </Modal>
      )}
    </div>
  );
}

export function CycleView({ user, cycle, onAdd, refreshKey }: any) {
  const [history, setHistory] = useState<any[]>([]),
    [month, setMonth] = useState(new Date());
  useEffect(() => {
    api("/cycle")
      .then((r) => setHistory(r.history))
      .catch(() => {});
  }, [refreshKey]);
  const year = month.getFullYear(),
    m = month.getMonth();
  const first = (new Date(year, m, 1).getDay() + 6) % 7;
  const days = new Date(year, m + 1, 0).getDate();
  const today = localDate(new Date(), user.timezone);
  const start = cycle?.start_date;
  return (
    <div className="two-columns">
      <section className="card padded cycle-main">
        <span className="cycle-big-icon">
          <Moon size={34} />
        </span>
        <span className="eyebrow">ВАШ ЦИКЛ</span>
        <h2>{cycle ? "День " + cycle.day : "Узнавайте свой ритм"}</h2>
        <h3>{cycle?.label || "Начните с первого дня менструации"}</h3>
        <p>
          Фазы — приблизительный ориентир. Мы не применяем универсальные
          коэффициенты к инсулину.
        </p>
        <button className="primary" onClick={onAdd}>
          <Plus size={17} />
          Отметить начало цикла
        </button>
        {cycle && (
          <div className="cycle-facts">
            <div className="data-row">
              <span>Начало цикла</span>
              <b>{cycle.start_date}</b>
            </div>
            <div className="data-row">
              <span>Обычная длина</span>
              <b>{cycle.cycle_length} дней</b>
            </div>
            <div className="data-row">
              <span>Расчётная овуляция</span>
              <b>{cycle.predicted_ovulation_date}</b>
            </div>
          </div>
        )}
      </section>
      <section className="card padded">
        <div className="section-title">
          <button
            aria-label="Предыдущий месяц"
            onClick={() => setMonth(new Date(year, m - 1, 1))}
          >
            ‹
          </button>
          <h2>
            {month.toLocaleDateString("ru-RU", {
              month: "long",
              year: "numeric",
            })}
          </h2>
          <button
            aria-label="Следующий месяц"
            onClick={() => setMonth(new Date(year, m + 1, 1))}
          >
            ›
          </button>
        </div>
        <div className="calendar">
          {["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"].map((d) => (
            <span className="week-label" key={d}>
              {d}
            </span>
          ))}
          {Array.from({ length: first }, (_, i) => (
            <span key={"pad" + i} />
          ))}
          {Array.from({ length: days }, (_, i) => {
            const date = localDate(new Date(year, m, i + 1, 12), user.timezone);
            const cd = start
              ? Math.round(
                  (new Date(date).getTime() - new Date(start).getTime()) /
                    86400000,
                ) + 1
              : 0;
            return (
              <span
                key={i}
                className={
                  "calendar-day " +
                  (date === today ? "today " : "") +
                  (cd > 0 && cd <= 5
                    ? "menstrual "
                    : date === cycle?.predicted_ovulation_date
                      ? "ovulation "
                      : "")
                }
              >
                {i + 1}
              </span>
            );
          })}
        </div>
        <div className="calendar-key">
          <span>
            <i className="period-dot" />
            Менструация · расчёт
          </span>
          <span>
            <i className="ovulation-dot" />
            Предполагаемая овуляция
          </span>
        </div>
        <h3 className="small-heading">История циклов</h3>
        {history.length ? (
          history.map((c) => (
            <div key={c.id} className="data-row">
              <span>{c.start_date}</span>
              <b>{c.cycle_length} дней</b>
            </div>
          ))
        ) : (
          <p className="subtle-note">Пока нет сохранённых циклов</p>
        )}
      </section>
    </div>
  );
}

const themeList = [
  ["light", "Minimal Light", "#f4f8f6"],
  ["dark", "Minimal Dark", "#253436"],
  ["cat", "Cat Café", "#e9dfcf"],
  ["pink", "Pink Pastel", "#f6dce6"],
  ["dino", "Dino", "#cce2bc"],
  ["oled", "OLED Black", "#030404"],
];
const pets = [
  ["cat", "🐱", "Кот"],
  ["pig", "🐷", "Поросёнок"],
  ["dinosaur", "🦕", "Динозавр"],
  ["rabbit", "🐰", "Кролик"],
  ["otter", "🦦", "Выдра"],
  ["panda", "🐼", "Панда"],
];
export function ProfileView({
  user,
  profile,
  setUser,
  onProfile,
  onHealth,
  onAuth,
  onAI,
  onReports,
  showToast,
  onLogout,
  onDelete,
}: any) {
  const [data, setData] = useState({ ...user }),
    [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [history, setHistory] = useState<any[]>([]),
    [showHistory, setShowHistory] = useState(false);
  useEffect(() => setData({ ...user }), [user]);
  const update = async (patch: any) => {
    setBusy(true);
    setError("");
    try {
      const d = { ...data, ...patch };
      const u = await api("/users/me", {
        method: "PATCH",
        body: JSON.stringify({
          name: d.name,
          timezone: d.timezone,
          glucose_unit: d.glucose_unit,
          theme_id: d.theme_id,
          mascot_id: d.mascot_id,
        }),
      });
      setUser(u);
      setData(u);
      showToast("Настройки сохранены");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="view-stack">
      <ErrorBox message={error} />
      <div className="two-columns">
        <section className="card padded">
          <div className="section-title">
            <h2>О вас</h2>
            <Settings size={20} />
          </div>
          <form
            className="form"
            onSubmit={(e) => {
              e.preventDefault();
              update({});
            }}
          >
            <Field label="Имя">
              <input
                required
                maxLength={80}
                value={data.name}
                onChange={(e) => setData({ ...data, name: e.target.value })}
              />
            </Field>
            <Field label="Единицы глюкозы">
              <select
                value={data.glucose_unit}
                onChange={(e) =>
                  setData({ ...data, glucose_unit: e.target.value })
                }
              >
                <option value="mmol/L">ммоль/л</option>
                <option value="mg/dL">мг/дл</option>
              </select>
            </Field>
            <Field label="Часовой пояс">
              <select
                value={data.timezone}
                onChange={(e) => setData({ ...data, timezone: e.target.value })}
              >
                {[
                  "Europe/Moscow",
                  "Europe/Kaliningrad",
                  "Europe/Samara",
                  "Asia/Yekaterinburg",
                  "Asia/Novosibirsk",
                  "Asia/Irkutsk",
                  "Asia/Vladivostok",
                  "Europe/Berlin",
                  "Europe/London",
                  "America/New_York",
                  "UTC",
                ].map((t) => (
                  <option key={t}>{t}</option>
                ))}
              </select>
            </Field>
            <Submit busy={busy}>Сохранить настройки</Submit>
          </form>
        </section>
        <section className="card padded">
          <div className="section-title">
            <h2>Терапевтический профиль</h2>
            <ShieldCheck size={20} />
          </div>
          {profile ? (
            <>
              <div className="profile-badge">
                Версия {profile.version} · подтверждён
              </div>
              <div className="data-row">
                <span>Терапия</span>
                <b>{profile.insulin_therapy_type}</b>
              </div>
              <div className="data-row">
                <span>Быстрый инсулин</span>
                <b>{profile.rapid_insulin_name || "—"}</b>
              </div>
              <div className="data-row">
                <span>Базальный инсулин</span>
                <b>{profile.basal_insulin_name || "—"}</b>
              </div>
              <div className="data-row">
                <span>Шаг болюса / базального</span>
                <b>
                  {decimal(profile.bolus_increment ?? 0.1)} /{" "}
                  {decimal(profile.basal_increment ?? 0.1)} ЕД
                </b>
              </div>
              <div className="data-row">
                <span>Действие инсулина</span>
                <b>{profile.insulin_action_duration} ч</b>
              </div>
              <div className="data-row">
                <span>Максимальный болюс</span>
                <b>{profile.max_bolus} ЕД</b>
              </div>
              <div className="table-scroll">
                <table>
                  <thead>
                    <tr>
                      <th>С</th>
                      <th>ICR</th>
                      <th>ISF</th>
                      <th>Цель</th>
                    </tr>
                  </thead>
                  <tbody>
                    {profile.segments.map((s: any) => (
                      <tr key={s.start_time}>
                        <td>{s.start_time}</td>
                        <td>{s.icr}</td>
                        <td>{s.isf}</td>
                        <td>{s.target}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </>
          ) : (
            <p className="empty-inline">
              Введите параметры терапии, согласованные с вашим специалистом.
            </p>
          )}
          <button className="secondary full" onClick={onProfile}>
            {profile ? "Изменить профиль" : "Настроить профиль"}
          </button>
          <button
            className="text-button centered"
            onClick={async () => {
              setHistory(await api("/profile/history"));
              setShowHistory(true);
            }}
          >
            История версий и расчётов
          </button>
        </section>
      </div>
      <section className="card padded">
        <div className="section-title">
          <h2>Ваше настроение</h2>
          <Palette size={20} />
        </div>
        <h3 className="small-heading">Тема оформления</h3>
        <div className="theme-options">
          {themeList.map(([id, label, color]) => (
            <button
              key={id}
              className={data.theme_id === id ? "selected" : ""}
              disabled={busy}
              onClick={() => update({ theme_id: id })}
            >
              <span style={{ background: color }}>
                {data.theme_id === id && <Check size={17} />}
              </span>
              {label}
            </button>
          ))}
        </div>
        <h3 className="small-heading">Маленький помощник</h3>
        <div className="pet-options">
          {pets.map(([id, emoji, label]) => (
            <button
              key={id}
              className={data.mascot_id === id ? "selected" : ""}
              disabled={busy}
              onClick={() => update({ mascot_id: id })}
            >
              <span>{emoji}</span>
              {label}
            </button>
          ))}
        </div>
        <p className="subtle-note">
          Ваш помощник всегда на вашей стороне. Его настроение не зависит от
          показателей глюкозы.
        </p>
      </section>
      <div className="two-columns">
        <section className="card padded">
          <h2>Подключения</h2>
          <button className="settings-row" onClick={onAI}>
            <Sparkles size={22} />
            <div>
              <b>OpenAI / Tokenn</b>
              <small>API-ключ, модель, анализ дневника и расход токенов</small>
            </div>
            <ChevronRight size={17} />
          </button>
          <button className="settings-row" onClick={onHealth}>
            <Heart size={22} />
            <div>
              <b>Apple «Здоровье»</b>
              <small>Импорт тренировок и активности из файла</small>
            </div>
            <ChevronRight size={17} />
          </button>
          <p className="subtle-note">
            Автоматическая синхронизация HealthKit требует приложения для iOS и
            разрешения на чтение данных.
          </p>
        </section>
        <section className="card padded">
          <h2>Ваши данные</h2>
          <button className="settings-row" onClick={onReports}>
            <Download size={21} />
            <div>
              <b>Экспортировать все данные</b>
              <small>PDF, Excel, CSV и полная JSON-копия</small>
            </div>
            <ChevronRight size={17} />
          </button>
          <button className="settings-row" onClick={onLogout}>
            <LogOut size={21} />
            <b>Выйти из аккаунта</b>
          </button>
          <button className="text-button danger-text" onClick={onDelete}>
            Удалить аккаунт и все данные
          </button>
        </section>
      </div>
      {showHistory && (
        <HistoryModal history={history} onClose={() => setShowHistory(false)} />
      )}
    </div>
  );
}
function HistoryModal({ history, onClose }: any) {
  const [calcs, setCalcs] = useState<any[]>([]);
  useEffect(() => {
    api("/bolus/history")
      .then(setCalcs)
      .catch(() => {});
  }, []);
  return (
    <Modal title="История профиля и расчётов" wide onClose={onClose}>
      <h3 className="small-heading">Профили</h3>
      {history.map((p: any) => (
        <div key={p.id} className="data-row">
          <span>
            Версия {p.version} · {p.valid_from.slice(0, 10)}
          </span>
          <b>{p.status === "active" ? "Активна" : "Архив"}</b>
        </div>
      ))}
      <h3 className="small-heading">Расчёты</h3>
      {calcs.length ? (
        <div className="table-scroll">
          <table>
            <thead>
              <tr>
                <th>Дата</th>
                <th>Расчёт</th>
                <th>Факт</th>
                <th>Алгоритм</th>
              </tr>
            </thead>
            <tbody>
              {calcs.map((c) => (
                <tr key={c.id}>
                  <td>{new Date(c.calculated_at).toLocaleString("ru-RU")}</td>
                  <td>
                    {decimal(c.calculation_snapshot.recommended_bolus)} ЕД
                  </td>
                  <td>{decimal(c.actual_bolus)} ЕД</td>
                  <td>{c.algorithm_version}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <p className="subtle-note">Расчётов пока нет</p>
      )}
    </Modal>
  );
}
