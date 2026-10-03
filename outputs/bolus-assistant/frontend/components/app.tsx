"use client";
import { useState, useEffect, useCallback } from "react";
import {
  Activity,
  BookOpen,
  ChartNoAxesCombined,
  ChevronLeft,
  ChevronRight,
  Droplet,
  Heart,
  Home,
  Leaf,
  Plus,
  Settings,
  ShieldCheck,
  Sparkles,
  Syringe,
  Utensils,
  Download,
  Moon,
  ArrowUpRight,
  WifiOff,
  RefreshCw,
  LogOut,
  FileText,
  Calculator,
  Link,
  Cloud,
} from "lucide-react";
import { api, post, decimal, localDate, ApiError } from "@/services/api";
import { pending, syncQueue, clearQueue } from "@/services/offline";
import { Modal, Empty, EventRow, ErrorBox, eventIcons } from "./ui";
import { GlucoseChart } from "./chart";
import { UnifiedEntryForm } from "./unified-entry";
import { AssistantView, AISettingsForm } from "./ai-assistant";
import {
  EntryForm,
  MealForm,
  BolusForm,
  CycleForm,
  AuthForm,
  ProfileForm,
  FoodForm,
  RecipeForm,
  HealthImport,
  OnboardingForm,
} from "./forms";
import {
  AnalyticsView,
  ReportsView,
  FoodsView,
  CycleView,
  ProfileView,
} from "./views";
const nav = [
  ["Сегодня", Home],
  ["Дневник", BookOpen],
  ["Аналитика", ChartNoAxesCombined],
  ["Питание", Utensils],
  ["Цикл", Moon],
  ["Отчёты", Download],
  ["Ассистент", Sparkles],
] as const;
const pets: any = {
  cat: "🐱",
  pig: "🐷",
  dinosaur: "🦕",
  rabbit: "🐰",
  otter: "🦦",
  panda: "🐼",
};
export default function BolusApp() {
  const [user, setUser] = useState<any>(null),
    [tab, setTab] = useState("Сегодня"),
    [modal, setModal] = useState(""),
    [selected, setSelected] = useState<any>(null),
    [entries, setEntries] = useState<any[]>([]),
    [profile, setProfile] = useState<any>(null),
    [config, setConfig] = useState<any>(null),
    [entrySection, setEntrySection] = useState("glucose"),
    [aiCalculation, setAiCalculation] = useState<string | null>(null),
    [iob, setIob] = useState(0),
    [cycle, setCycle] = useState<any>(null),
    [metrics, setMetrics] = useState<any>({}),
    [busy, setBusy] = useState(true),
    [error, setError] = useState(""),
    [toast, setToast] = useState(""),
    [offline, setOffline] = useState(false),
    [queued, setQueued] = useState<any[]>([]),
    [date, setDate] = useState(localDate()),
    [filter, setFilter] = useState("all"),
    [refreshKey, setRefreshKey] = useState(0),
    [chartPeriod, setChartPeriod] = useState(1),
    [chartEntries, setChartEntries] = useState<any[]>([]),
    [chartMetrics, setChartMetrics] = useState<any>({}),
    [latest, setLatest] = useState<any>(null);
  const showToast = (text: string) => {
    setToast(text);
    setTimeout(() => setToast(""), 5000);
  };
  const refresh = useCallback(
    async (u = user) => {
      if (!u) return;
      const today = localDate(new Date(), u.timezone);
      try {
        const [diary, p, ins, c, a, latestGlucose, serverConfig] =
          await Promise.all([
            api("/diary?date_from=" + today + "&date_to=" + today),
            api("/profile"),
            api("/iob"),
            api("/cycle"),
            api("/analytics?days=1"),
            api("/glucose/latest"),
            api("/config"),
          ]);
        setLatest(latestGlucose);
        setEntries(diary);
        setProfile(p);
        setIob(ins.iob);
        setCycle(c.current);
        setMetrics(a.metrics);
        setConfig(serverConfig);
        setError("");
        setRefreshKey((k) => k + 1);
        setQueued(await pending(u.id));
      } catch (e) {
        setError(e instanceof Error ? e.message : "Ошибка загрузки");
      }
    },
    [user],
  );
  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        let u;
        try {
          u = await api("/users/me");
        } catch (e) {
          if (e instanceof ApiError && e.status === 401) {
            localStorage.removeItem("bolus-account");
            return;
          } else if (e instanceof ApiError && e.status === 0) {
            const cached = localStorage.getItem("bolus-account");
            if (cached) {
              u = JSON.parse(cached);
              if (u.is_demo) {
                localStorage.removeItem("bolus-account");
                return;
              }
              setOffline(true);
            } else throw e;
          } else throw e;
        }
        if (!alive) return;
        setUser(u);
        localStorage.setItem("bolus-account", JSON.stringify(u));
        setDate(localDate(new Date(), u.timezone));
        await refresh(u);
      } catch (e) {
        setError(e instanceof Error ? e.message : "Не удалось открыть дневник");
      } finally {
        if (alive) setBusy(false);
      }
    })();
    return () => {
      alive = false;
    };
  }, []);
  useEffect(() => {
    if (!user) return;
    document.documentElement.dataset.theme = user.theme_id;
    localStorage.setItem("bolus-account", JSON.stringify(user));
    const online = async () => {
      setOffline(false);
      await syncQueue(user.id);
      await refresh(user);
    };
    const off = () => setOffline(true);
    setOffline(!navigator.onLine);
    window.addEventListener("online", online);
    window.addEventListener("offline", off);
    syncQueue(user.id)
      .then(() => pending(user.id))
      .then(setQueued);
    if ("serviceWorker" in navigator)
      navigator.serviceWorker
        .register("/sw.js")
        .then(async (registration) => {
          await navigator.serviceWorker.ready;
          const urls = Array.from(
            document.querySelectorAll("script[src],link[rel=stylesheet]"),
          )
            .map((el) => el.getAttribute("src") || el.getAttribute("href"))
            .filter(Boolean);
          (registration.active || registration.waiting)?.postMessage({
            type: "CACHE_SHELL",
            urls,
          });
        })
        .catch(() => {});
    return () => {
      window.removeEventListener("online", online);
      window.removeEventListener("offline", off);
    };
  }, [user?.id, user?.theme_id]);
  useEffect(() => {
    if (user)
      api("/analytics?days=" + (chartPeriod === 1 ? "2&hours=24" : chartPeriod))
        .then((a) => {
          setChartEntries(a.entries);
          setChartMetrics(a.metrics);
        })
        .catch(() => {});
  }, [chartPeriod, refreshKey, user?.id]);
  useEffect(() => {
    if (!user) return;
    const timer = setInterval(() => {
      if (navigator.onLine)
        Promise.all([api("/iob"), api("/glucose/latest")])
          .then(([v, g]) => {
            setIob(v.iob);
            setLatest(g);
          })
          .catch(() => {});
    }, 30000);
    return () => clearInterval(timer);
  }, [user?.id]);
  const [diaryRows, setDiaryRows] = useState<any[]>([]),
    [diaryLoading, setDiaryLoading] = useState(false);
  useEffect(() => {
    if (tab !== "Дневник" || !user) return;
    setDiaryLoading(true);
    api("/diary?date_from=" + date + "&date_to=" + date)
      .then(setDiaryRows)
      .catch((e) => setError(e.message))
      .finally(() => setDiaryLoading(false));
  }, [tab, date, refreshKey, user?.id]);
  const saved = async (message = "Запись сохранена") => {
    setModal("");
    setSelected(null);
    showToast(message);
    await refresh();
  };
  const open = (name: string) => {
    setError("");
    if (
      [
        "add",
        "glucose",
        "meal",
        "insulin",
        "activity",
        "cycle",
        "note",
      ].includes(name)
    ) {
      setEntrySection(name === "add" ? "glucose" : name);
      setModal("entry");
      return;
    }
    setModal(name);
  };
  const explain = (id: string) => {
    setAiCalculation(id);
    setModal("");
    setTab("Ассистент");
  };
  const carbs = entries
    .filter((e) => e.kind === "meal")
    .reduce((s, e) => s + e.data.total_carbs, 0);
  const mealCount = entries.filter((e) => e.kind === "meal").length;
  const insulinToday = entries
    .filter((e) => e.kind === "insulin")
    .reduce((s, e) => s + e.data.units, 0);
  const factor = user?.glucose_unit === "mg/dL" ? 18 : 1;
  const unit = factor === 18 ? "мг/дл" : "ммоль/л";
  const heading: any = {
    Сегодня: `Добрый ${new Date().getHours() < 12 ? "день" : new Date().getHours() < 18 ? "день" : "вечер"}, ${user?.name || "друг"}`,
    Дневник: "Ваш дневник",
    Аналитика: "Чуть больше понимания",
    Питание: "Еда, которая вам нравится",
    Цикл: "В вашем ритме",
    Отчёты: "Экспорт и отчёты",
    Профиль: "Ваше пространство",
    Ассистент: "Ваш AI-ассистент",
  };
  const subtitles: any = {
    Сегодня: "Всё важное о вашем дне — в одном месте.",
    Дневник: "Маленькие наблюдения складываются в большую картину.",
    Аналитика: "Замечайте закономерности, опираясь на свои данные.",
    Питание: "Продукты, любимые блюда и понятный подсчёт углеводов.",
    Цикл: "Каждый цикл индивидуален. Узнавайте свой.",
    Отчёты: "Ваши наблюдения — в удобном формате.",
    Профиль: "Настройки, которые подходят именно вам.",
    Ассистент: "Понятные объяснения ваших наблюдений.",
  };
  if (busy)
    return (
      <div className="boot">
        <div className="brand">
          <span className="brand-mark">
            <Droplet />
          </span>
          bolus.
        </div>
        <div className="loading-line" />
        <p>Открываем ваш дневник…</p>
      </div>
    );
  if (!user)
    return (
      <div className="auth-page">
        <div className="brand">
          <Droplet />
          bolus.
        </div>
        <h1>Дневник вашей заботы</h1>
        <p>Глюкоза, питание и активность — в одном месте.</p>
        <ErrorBox message={error} />
        <AuthForm
          onSuccess={async (u: any) => {
            setUser(u);
            await refresh(u);
            const existing = await api("/profile");
            if (!existing) {
              setTab("Профиль");
              setModal("profile");
            }
          }}
        />
      </div>
    );
  return (
    <div className="app-shell">
      <aside className="sidebar">
        <button className="brand" onClick={() => setTab("Сегодня")}>
          <span className="brand-mark">
            <Droplet size={24} />
          </span>
          bolus<span className="brand-dot">.</span>
        </button>
        <span className="brand-caption">МАЛЕНЬКИЕ ШАГИ. БОЛЬШЕ ЗАБОТЫ.</span>
        <nav>
          {nav.map(([name, Icon]) => (
            <button
              key={name}
              onClick={() => setTab(name)}
              className={tab === name ? "nav-item active" : "nav-item"}
            >
              <Icon size={20} />
              {name}
              {tab === name && <span className="nav-pip" />}
            </button>
          ))}
        </nav>
        <div className="sidebar-bottom">
          <div className="safe-note">
            <ShieldCheck size={20} />
            <div>
              Ваше пространство заботы<small>Данные под вашим контролем</small>
            </div>
          </div>
          <button
            className={"nav-item " + (tab === "Профиль" ? "active" : "")}
            onClick={() => setTab("Профиль")}
          >
            <Settings size={20} />
            Настройки
          </button>
          <button className="user-card" onClick={() => setTab("Профиль")}>
            <div className="avatar">{user.name[0]}</div>
            <div>
              <b>{user.name}</b>
              <small>Мой профиль</small>
            </div>
            <ChevronRight size={16} />
          </button>
        </div>
      </aside>
      <div className="workspace">
        <header className="topbar">
          <span className="breadcrumb">
            Мой дневник <ChevronRight size={14} /> <b>{tab}</b>
          </span>
          <div className="top-right">
            {offline ? (
              <WifiOff size={17} />
            ) : (
              <span className="sync-status">
                <Cloud size={15} />
                Сохранено
              </span>
            )}
            <span className="header-date">
              {new Date().toLocaleDateString("ru-RU", {
                timeZone: user.timezone,
                day: "numeric",
                month: "long",
                year: "numeric",
              })}
            </span>
            <button className="avatar small" onClick={() => setTab("Профиль")}>
              {user.name[0]}
            </button>
          </div>
        </header>
        <main>
          <div className="page-heading">
            <div>
              <div className="eyebrow">
                {new Date()
                  .toLocaleDateString("ru-RU", {
                    timeZone: user.timezone,
                    weekday: "long",
                    day: "numeric",
                    month: "long",
                  })
                  .toUpperCase()}
              </div>
              <h1>
                {heading[tab]}
                {tab === "Сегодня" && <span className="hello">✳</span>}
              </h1>
              <p>{subtitles[tab]}</p>
            </div>
            <button
              className="primary"
              aria-label="Добавить запись"
              onClick={() => open("add")}
            >
              <Plus size={19} />
              Добавить запись
            </button>
          </div>
          <ErrorBox message={error} />
          {offline && (
            <div className="info-box">
              <WifiOff size={17} />
              Вы офлайн. Глюкоза, инсулин и черновики еды сохраняются на этом
              устройстве. Расчёт болюса недоступен.
            </div>
          )}
          {queued.length > 0 && (
            <button className="info-box full" onClick={() => open("queue")}>
              Ожидают синхронизации: {queued.length}.{" "}
              {queued.some((q) => q.error)
                ? "Есть записи, требующие проверки."
                : "Отправим после подключения."}
            </button>
          )}
          {tab === "Сегодня" && (
            <div className="dashboard-grid">
              <section className="main-column">
                <div className="metrics">
                  <article className="metric glucose">
                    <div className="metric-label">
                      <Droplet size={18} />
                      Последняя глюкоза{latest && <span className="live-dot" />}
                    </div>
                    <div className="metric-value">
                      {decimal(latest?.data.value_mmol * factor || null)}{" "}
                      {latest && (
                        <span className="trend">
                          {
                            (
                              {
                                rapid_down: "↓↓",
                                down: "↓",
                                slight_down: "↘",
                                stable: "→",
                                slight_up: "↗",
                                up: "↑",
                                rapid_up: "↑↑",
                                unknown: "",
                              } as any
                            )[latest.data.trend]
                          }
                        </span>
                      )}
                      <small>{unit}</small>
                    </div>
                    <div className="metric-footer">
                      {latest ? (
                        <>
                          <span className="pill">
                            {latest.data.value_mmol < 3.9
                              ? "Ниже диапазона"
                              : latest.data.value_mmol > 10
                                ? "Выше диапазона"
                                : "В диапазоне"}
                          </span>
                          <span>
                            {new Date(latest.occurred_at).toLocaleTimeString(
                              "ru-RU",
                              {
                                timeZone: user.timezone,
                                hour: "2-digit",
                                minute: "2-digit",
                              },
                            )}{" "}
                            · вручную
                          </span>
                        </>
                      ) : (
                        <button
                          className="text-button"
                          onClick={() => open("glucose")}
                        >
                          Добавить измерение
                        </button>
                      )}
                    </div>
                    {latest && (
                      <svg
                        className="sparkline"
                        viewBox="0 0 260 55"
                        aria-hidden="true"
                      >
                        <path
                          d={entries
                            .filter((e) => e.kind === "glucose")
                            .slice(0, 15)
                            .reverse()
                            .map(
                              (e, i, a) =>
                                `${i ? "L" : "M"}${(i / Math.max(a.length - 1, 1)) * 260} ${55 - (Math.min(e.data.value_mmol, 15) / 15) * 50}`,
                            )
                            .join(" ")}
                          fill="none"
                          stroke="#339b80"
                          strokeWidth="2.5"
                        />
                      </svg>
                    )}
                  </article>
                  <article className="metric">
                    <div className="metric-label">
                      <Syringe size={18} />
                      Активный инсулин
                    </div>
                    <div className="metric-value">
                      {decimal(iob)} <small>ЕД</small>
                    </div>
                    <div className="metric-footer">
                      <span>IOB · сейчас</span>
                      <span className="mini-badge">
                        {profile?.insulin_action_duration || "—"} ч DIA
                      </span>
                    </div>
                    <div className="progress-track">
                      <span
                        style={{ width: `${Math.min((iob / 10) * 100, 100)}%` }}
                      />
                    </div>
                  </article>
                  <article className="metric">
                    <div className="metric-label">
                      <Utensils size={18} />
                      Углеводы сегодня
                    </div>
                    <div className="metric-value">
                      {decimal(carbs, 0)} <small>г</small>
                    </div>
                    <div className="metric-footer">
                      <span>Приёмов пищи: {mealCount}</span>
                    </div>
                    <div className="macro-dots">
                      <i />
                      <i />
                      <i />
                      <span>Инсулин за день: {decimal(insulinToday)} ЕД</span>
                    </div>
                  </article>
                </div>
                <div className="card chart-card">
                  <div className="card-heading">
                    <div>
                      <h2>
                        {chartPeriod === 1
                          ? "Глюкоза за 24 часа"
                          : "История глюкозы"}
                      </h2>
                      <p>
                        <span className="legend-dot" />
                        Глюкоза <span className="range-key" />
                        Диапазон {decimal(3.9 * factor)}–{10 * factor}
                      </p>
                    </div>
                    <div className="segmented">
                      {[
                        [1, "24 ч"],
                        [7, "7 д"],
                        [14, "14 д"],
                      ].map(([n, label]) => (
                        <button
                          key={n}
                          className={chartPeriod === n ? "selected" : ""}
                          onClick={() => setChartPeriod(Number(n))}
                        >
                          {label}
                        </button>
                      ))}
                    </div>
                  </div>
                  <GlucoseChart
                    entries={chartEntries}
                    user={user}
                    {...({
                      unit: user.glucose_unit,
                      timezone: user.timezone,
                      onSelect: (e: any) => {
                        setSelected(e);
                        open("detail");
                      },
                    } as any)}
                  />
                  <div className="graph-events">
                    <span>
                      <i style={{ background: "#d5ae73" }} />
                      Еда
                    </span>
                    <span>
                      <i style={{ background: "#b0a0ce" }} />
                      Инсулин
                    </span>
                    <span>
                      <i style={{ background: "#7ca9cb" }} />
                      Активность
                    </span>
                    <small>Нажмите на событие</small>
                  </div>
                  <div className="chart-summary">
                    <span>
                      <i className="legend-dot" />В диапазоне{" "}
                      <b>{decimal(chartMetrics.tir, 0)}%</b>
                    </span>
                    <span>
                      Средняя глюкоза{" "}
                      <b>
                        {decimal(
                          chartMetrics.mean_glucose
                            ? chartMetrics.mean_glucose * factor
                            : null,
                        )}{" "}
                        <small>{unit}</small>
                      </b>
                    </span>
                    <span>
                      Записей <b>{chartMetrics.sample_size || 0}</b>
                    </span>
                  </div>
                </div>
                <div className="card diary-card">
                  <div className="card-heading">
                    <h2>
                      События сегодня{" "}
                      <span className="count">{entries.length}</span>
                    </h2>
                    <button
                      className="text-button"
                      onClick={() => setTab("Дневник")}
                    >
                      Весь дневник <ChevronRight size={16} />
                    </button>
                  </div>
                  {entries.length ? (
                    entries.slice(0, 4).map((e) => (
                      <EventRow
                        key={e.id}
                        entry={e}
                        user={user}
                        onClick={() => {
                          setSelected(e);
                          open("detail");
                        }}
                      />
                    ))
                  ) : (
                    <Empty action={() => open("add")} />
                  )}
                </div>
              </section>
              <aside className="right-column">
                <div className="mascot-card">
                  <span className="mascot-label">
                    <Leaf size={15} />
                    На вашей стороне
                  </span>
                  <div className="mascot-art">
                    {user.mascot_id === "cat" ? (
                      <img
                        src="/mascot-cat.png"
                        alt="Кот Персик, ваш помощник"
                      />
                    ) : (
                      pets[user.mascot_id]
                    )}
                  </div>
                  <h2>
                    Забота начинается
                    <br />с маленьких шагов
                  </h2>
                  <p>
                    Одна запись — уже внимание к себе.
                    <br />
                    Вы в своём ритме, и это хорошо.
                  </p>
                  <div className="mascot-bottom">
                    <span>
                      {user.mascot_id === "cat"
                        ? "Ваш помощник Персик"
                        : "Ваш маленький помощник"}
                    </span>
                    <Heart size={15} />
                  </div>
                </div>
                <button className="bolus-card" onClick={() => open("bolus")}>
                  <span className="bolus-icon">
                    <Calculator size={23} />
                  </span>
                  <div>
                    <b>Рассчитать болюс</b>
                    <small>С понятной расшифровкой</small>
                  </div>
                  <ChevronRight size={18} />
                </button>
                <button
                  className="card cycle-card"
                  onClick={() => setTab("Цикл")}
                >
                  <div className="cycle-icon">
                    <Moon size={23} />
                  </div>
                  <div>
                    <span>ВАШ ЦИКЛ</span>
                    <h3>{cycle ? "День " + cycle.day : "В вашем ритме"}</h3>
                    <p>{cycle?.label || "Добавить начало цикла"}</p>
                  </div>
                  <ChevronRight size={17} />
                  <div className="cycle-days">
                    {Array.from(
                      { length: cycle?.cycle_length || 28 },
                      (_, i) => (
                        <i
                          key={i}
                          className={
                            i < 5
                              ? "period"
                              : i === cycle?.day - 1
                                ? "current"
                                : ""
                          }
                        />
                      ),
                    )}
                  </div>
                  <small>Расчётная фаза · каждый цикл индивидуален</small>
                </button>
                <button
                  className="insight-card"
                  onClick={() => setTab("Аналитика")}
                >
                  <div className="insight-title">
                    <Sparkles size={18} />
                    <b>Чуть больше понимания</b>
                  </div>
                  <p>
                    Замечайте закономерности
                    <br />
                    вместе с вашим дневником.
                  </p>
                  <span>
                    Открыть аналитику <ChevronRight size={15} />
                  </span>
                </button>
                <button className="health-card" onClick={() => open("health")}>
                  <Heart size={21} />
                  <div>
                    <b>Apple «Здоровье»</b>
                    <small>Добавьте тренировки в дневник</small>
                  </div>
                  <ChevronRight size={15} />
                </button>
              </aside>
            </div>
          )}
          {tab === "Дневник" && (
            <div className="card diary-full">
              <div className="diary-controls">
                <div className="date-picker">
                  <button
                    aria-label="Предыдущий день"
                    onClick={() => {
                      const d = new Date(date + "T12:00:00");
                      d.setDate(d.getDate() - 1);
                      setDate(localDate(d, user.timezone));
                    }}
                  >
                    <ChevronLeft size={19} />
                  </button>
                  <input
                    aria-label="Дата дневника"
                    type="date"
                    value={date}
                    max={localDate(new Date(), user.timezone)}
                    onChange={(e) => setDate(e.target.value)}
                  />
                  <button
                    aria-label="Следующий день"
                    disabled={date >= localDate(new Date(), user.timezone)}
                    onClick={() => {
                      const d = new Date(date + "T12:00:00");
                      d.setDate(d.getDate() + 1);
                      setDate(localDate(d, user.timezone));
                    }}
                  >
                    <ChevronRight size={19} />
                  </button>
                </div>
                <button className="text-button" onClick={() => open("health")}>
                  <Heart size={16} />
                  Импорт из «Здоровья»
                </button>
              </div>
              <div className="filter-tabs">
                {[
                  ["all", "Все"],
                  ["glucose", "Глюкоза"],
                  ["meal", "Еда"],
                  ["insulin", "Инсулин"],
                  ["activity", "Активность"],
                  ["note", "Заметки"],
                ].map(([id, label]) => (
                  <button
                    key={id}
                    className={filter === id ? "active" : ""}
                    onClick={() => setFilter(id)}
                  >
                    {label}
                  </button>
                ))}
              </div>
              {diaryLoading ? (
                <div className="loading-state">Загружаем записи…</div>
              ) : diaryRows.filter(
                  (e) =>
                    filter === "all" ||
                    e.kind === filter ||
                    (filter === "activity" && e.kind === "activity_summary"),
                ).length ? (
                diaryRows
                  .filter(
                    (e) =>
                      filter === "all" ||
                      e.kind === filter ||
                      (filter === "activity" && e.kind === "activity_summary"),
                  )
                  .map((e) => (
                    <EventRow
                      key={e.id}
                      entry={e}
                      user={user}
                      onClick={() => {
                        setSelected(e);
                        open("detail");
                      }}
                    />
                  ))
              ) : (
                <Empty action={() => open("add")} />
              )}
            </div>
          )}
          {tab === "Аналитика" && (
            <AnalyticsView
              user={user}
              refreshKey={refreshKey}
              onAssistant={() => setTab("Ассистент")}
              onHealth={() => open("health")}
            />
          )}
          {tab === "Питание" && (
            <FoodsView
              onAdd={() => open("meal")}
              onCustom={() => open("food")}
              onRecipe={() => open("recipe")}
              refreshKey={refreshKey}
            />
          )}
          {tab === "Цикл" && (
            <CycleView
              user={user}
              cycle={cycle}
              onAdd={() => open("cycle")}
              refreshKey={refreshKey}
            />
          )}
          {tab === "Отчёты" && (
            <ReportsView user={user} showToast={showToast} />
          )}
          {tab === "Профиль" && (
            <ProfileView
              user={user}
              profile={profile}
              setUser={setUser}
              onProfile={() => open("profile")}
              onHealth={() => open("health")}
              onAuth={() => open("auth")}
              onAI={() => open("ai-settings")}
              onReports={() => setTab("Отчёты")}
              showToast={showToast}
              onLogout={async () => {
                if ((await pending(user.id)).length) {
                  showToast(
                    "Сначала синхронизируйте записи, ожидающие отправки.",
                  );
                  return;
                }
                localStorage.removeItem("bolus-account");
                await post("/auth/logout");
                setUser(null);
                setEntries([]);
              }}
              onDelete={() => open("delete-account")}
            />
          )}
          {tab === "Ассистент" && (
            <AssistantView
              key={refreshKey}
              calculationId={aiCalculation}
              onSettings={() => open("ai-settings")}
              onClearCalculation={() => setAiCalculation(null)}
            />
          )}
          <footer>
            <span>
              <ShieldCheck size={14} />
              Только вы управляете своими данными
            </span>
            <span>Каждый день — новый маленький шаг</span>
          </footer>
        </main>
      </div>
      <nav className="bottom-nav">
        {[
          ["Сегодня", Home],
          ["Дневник", BookOpen],
          ["Добавить", Plus],
          ["Аналитика", ChartNoAxesCombined],
          ["Профиль", Settings],
        ].map(([label, Icon]) => (
          <button
            key={String(label)}
            className={tab === label ? "active" : ""}
            onClick={() =>
              label === "Добавить" ? open("add") : setTab(String(label))
            }
          >
            {typeof Icon !== "string" && <Icon size={22} />}
            <span>{String(label)}</span>
          </button>
        ))}
      </nav>
      {modal === "entry" && (
        <Modal
          title="Добавить запись"
          description="Одна страница — только нужные вам поля."
          wide
          onClose={() => setModal("")}
        >
          <UnifiedEntryForm
            user={user}
            profile={profile}
            latest={latest}
            offline={offline}
            clinicalUseEnabled={Boolean(config?.clinical_use_enabled)}
            initialSection={entrySection}
            onRefresh={refresh}
            onExplain={explain}
          />
        </Modal>
      )}
      {["glucose", "insulin", "activity", "note"].includes(modal) && (
        <Modal
          title={
            (
              {
                glucose: "Добавить глюкозу",
                insulin: "Записать инсулин",
                activity: "Добавить активность",
                note: "Новая заметка",
              } as any
            )[modal]
          }
          onClose={() => setModal("")}
        >
          <EntryForm
            kind={modal}
            user={user}
            profile={profile}
            onSaved={saved}
          />
        </Modal>
      )}
      {modal === "meal" && (
        <Modal
          title="Добавить еду"
          description="Найдите продукт и укажите количество."
          wide
          onClose={() => setModal("")}
        >
          <MealForm
            user={user}
            onSaved={saved}
            onBolus={async (meal: any) => {
              await refresh();
              setSelected(meal);
              setModal("bolus");
            }}
          />
        </Modal>
      )}
      {modal === "bolus" && (
        <Modal
          title="Рассчитать болюс"
          description="Расчёт по вашему подтверждённому профилю."
          onClose={() => {
            setModal("");
            setSelected(null);
          }}
        >
          <BolusForm
            user={user}
            profile={profile}
            latest={latest}
            meal={selected?.kind === "meal" ? selected : null}
            offline={offline}
            clinicalUseEnabled={Boolean(config?.clinical_use_enabled)}
            onExplain={explain}
            onSaved={saved}
            onProfile={() => setModal("profile")}
          />
        </Modal>
      )}
      {modal === "cycle" && (
        <Modal title="Начало цикла" onClose={() => setModal("")}>
          <CycleForm user={user} onSaved={saved} />
        </Modal>
      )}
      {modal === "profile" && (
        <Modal
          title="Терапевтический профиль"
          description="Используйте параметры, согласованные с вашим лечащим специалистом."
          wide
          onClose={() => setModal("")}
        >
          <ProfileForm profile={profile} onSaved={saved} />
        </Modal>
      )}
      {modal === "ai-settings" && (
        <Modal title="Подключение AI" onClose={() => setModal("")}>
          <AISettingsForm onSaved={() => setRefreshKey((k) => k + 1)} />
        </Modal>
      )}
      {modal === "food" && (
        <Modal title="Свой продукт" onClose={() => setModal("")}>
          <FoodForm onSaved={saved} />
        </Modal>
      )}
      {modal === "recipe" && (
        <Modal
          title="Моё блюдо"
          description="Добавьте ингредиенты и вес готового блюда."
          wide
          onClose={() => setModal("")}
        >
          <RecipeForm onSaved={saved} />
        </Modal>
      )}
      {modal === "health" && (
        <Modal
          title="Apple «Здоровье»"
          description="Тренировки и активность — часть вашей истории."
          onClose={() => setModal("")}
        >
          <HealthImport onSaved={saved} />
        </Modal>
      )}
      {modal === "auth" && (
        <Modal
          title="Ваш личный дневник"
          description="Вход в ваш дневник."
          onClose={() => setModal("")}
        >
          <AuthForm
            onSuccess={async (u: any) => {
              setUser(u);
              const existingProfile = await api("/profile");
              setModal(existingProfile ? "" : "profile");
              setEntries([]);
              setTab("Профиль");
              await refresh(u);
              showToast("Добро пожаловать в ваш дневник");
            }}
          />
        </Modal>
      )}
      {modal === "detail" && selected && (
        <Modal title="Запись в дневнике" onClose={() => setModal("")}>
          <EventRow entry={selected} user={user} />
          <div className="detail-info">
            {new Date(selected.occurred_at).toLocaleString("ru-RU", {
              timeZone: user.timezone,
            })}
            {selected.data.note && <p>{selected.data.note}</p>}
            {selected.data.items?.map((i: any, n: number) => (
              <p key={n}>
                {i.name_snapshot} · {i.unit === "ml" ? i.amount : i.grams}{" "}
                {i.unit === "ml" ? "мл" : "г"} · {decimal(i.carbs)} г углеводов
              </p>
            ))}
            {selected.kind === "activity" && (
              <p>
                Источник:{" "}
                {selected.data.source === "apple_health"
                  ? "Apple «Здоровье»"
                  : "Вручную"}
              </p>
            )}
            {selected.kind === "activity_summary" && (
              <div>
                {selected.data.steps != null && (
                  <p>Шаги: {decimal(selected.data.steps, 0)}</p>
                )}
                {selected.data.exercise_minutes != null && (
                  <p>
                    Упражнения: {decimal(selected.data.exercise_minutes)} мин
                  </p>
                )}
                {selected.data.active_energy != null && (
                  <p>
                    Активная энергия: {decimal(selected.data.active_energy)}{" "}
                    {selected.data.energy_unit || "ккал"}
                  </p>
                )}
                {selected.data.distance_km != null && (
                  <p>Ходьба и бег: {decimal(selected.data.distance_km)} км</p>
                )}
              </div>
            )}
          </div>
          <div className="form-actions">
            {selected.kind === "meal" && (
              <button className="primary" onClick={() => setModal("bolus")}>
                Рассчитать болюс
              </button>
            )}
            <button
              className="danger-outline"
              onClick={() => setModal("delete-entry")}
            >
              Удалить запись
            </button>
          </div>
        </Modal>
      )}
      {modal === "delete-entry" && (
        <Modal
          title="Удалить запись?"
          description="Запись исчезнет из дневника и текущей аналитики. Удаление инсулина изменит IOB."
          onClose={() => setModal("detail")}
        >
          <button
            className="danger full"
            onClick={async () => {
              try {
                await api(`/diary/${selected.id}?version=${selected.version}`, {
                  method: "DELETE",
                });
                await saved("Запись удалена");
              } catch (e) {
                showToast((e as Error).message);
              }
            }}
          >
            Удалить запись
          </button>
        </Modal>
      )}
      {modal === "delete-account" && (
        <Modal
          title="Удалить аккаунт и все данные?"
          description="Дневник, профиль и файлы отчётов будут удалены без восстановления. Сначала можно выгрузить JSON-копию."
          onClose={() => setModal("")}
        >
          <div className="form-actions">
            <button
              className="secondary"
              onClick={() => {
                setModal("");
                setTab("Отчёты");
              }}
            >
              Экспортировать данные
            </button>
            <button
              className="danger"
              onClick={async () => {
                try {
                  await api("/users/me", { method: "DELETE" });
                  await clearQueue(user.id);
                  localStorage.removeItem("bolus-account");
                  setModal("");
                  setUser(null);
                  setEntries([]);
                } catch (e) {
                  showToast((e as Error).message);
                }
              }}
            >
              Удалить всё
            </button>
          </div>
        </Modal>
      )}
      {modal === "onboarding" && (
        <Modal title="Настроим ваш дневник" onClose={() => setModal("")}>
          <OnboardingForm user={user} onUser={setUser} onSaved={saved} />
        </Modal>
      )}
      {modal === "queue" && (
        <Modal title="Ожидают отправки" onClose={() => setModal("")}>
          {queued.map((q) => (
            <div className="queue-item" key={q.id}>
              <b>{q.path}</b>
              <small>{new Date(q.queuedAt).toLocaleString("ru-RU")}</small>
              {q.error && <ErrorBox message={q.error} />}
            </div>
          ))}
          <button
            className="primary full"
            onClick={async () => {
              await syncQueue(user.id);
              setQueued(await pending(user.id));
              await refresh();
            }}
          >
            Повторить синхронизацию
          </button>
        </Modal>
      )}
      {toast && (
        <div className="toast" role="status">
          <ShieldCheck size={18} />
          {toast}
        </div>
      )}
    </div>
  );
}
