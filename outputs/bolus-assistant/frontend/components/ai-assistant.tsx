"use client";
import { useEffect, useState } from "react";
import { Sparkles, KeyRound, Send, Check } from "lucide-react";
import { api, post, decimal } from "@/services/api";
import { Field, ErrorBox } from "./ui";

export function AISettingsForm({ onSaved }: any) {
  const [config, setConfig] = useState<any>(null),
    [key, setKey] = useState(""),
    [model, setModel] = useState("gpt-4.1-mini"),
    [provider, setProvider] = useState("openai"),
    [consent, setConsent] = useState(false),
    [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [message, setMessage] = useState("");
  useEffect(() => {
    api("/ai/settings")
      .then((c) => {
        setConfig(c);
        setModel(c.model);
        setProvider(c.provider);
        setConsent(c.consent);
      })
      .catch((e) => setError(e.message));
  }, []);
  const run = async (fn: () => Promise<void>) => {
    setBusy(true);
    setError("");
    setMessage("");
    try {
      await fn();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  const providerName = provider === "tokenn" ? "Tokenn" : "OpenAI";
  const currentKey = config?.key_configured && config.provider === provider;
  const dirty =
    !!key ||
    model !== config?.model ||
    provider !== config?.provider ||
    consent !== config?.consent;
  return (
    <form
      className="form"
      onSubmit={(e) => {
        e.preventDefault();
        run(async () => {
          const c = await api("/ai/settings", {
            method: "PUT",
            body: JSON.stringify({
              api_key: key || null,
              provider,
              model: model.trim(),
              consent,
            }),
          });
          setConfig(c);
          setModel(c.model);
          setKey("");
          setMessage("Настройки AI сохранены");
          onSaved?.();
        });
      }}
    >
      <div className="info-box">
        <KeyRound size={20} />
        <span>
          Ключ хранится на сервере в зашифрованном виде. После сохранения он не
          возвращается в браузер.
        </span>
      </div>
      <Field
        label="Провайдер AI"
        hint="Ключ должен быть выпущен выбранным сервисом."
      >
        <select
          value={provider}
          onChange={(e) => {
            setProvider(e.target.value);
            setConsent(false);
            setKey("");
            setError("");
            setMessage("");
            if (e.target.value === "tokenn" && model === "gpt-4.1-mini")
              setModel("gpt-5.5");
          }}
        >
          <option value="openai">OpenAI напрямую</option>
          <option value="tokenn">Tokenn</option>
        </select>
      </Field>
      <p className="subtle-note">
        Адрес API:{" "}
        {provider === "tokenn"
          ? "https://api.tokenn.pro/v1"
          : "https://api.openai.com/v1"}
      </p>
      <Field
        label={`API-ключ ${providerName}`}
        hint={
          currentKey
            ? "Ключ сохранён. Оставьте поле пустым, чтобы его сохранить."
            : `Ключ из вашего аккаунта ${providerName}.`
        }
      >
        <input
          type="password"
          autoComplete="off"
          value={key}
          onChange={(e) => setKey(e.target.value)}
          placeholder={currentKey ? "Ключ сохранён" : "sk-…"}
          maxLength={512}
        />
      </Field>
      <Field
        label="Модель"
        hint="Укажите модель Responses API со Structured Outputs, доступную вашему ключу."
      >
        <input
          required
          pattern="gpt-[a-zA-Z0-9._-]+"
          maxLength={100}
          value={model}
          onChange={(e) => setModel(e.target.value)}
        />
      </Field>
      <label className="checkbox-row">
        <input
          type="checkbox"
          checked={consent}
          onChange={(e) => setConsent(e.target.checked)}
        />
        <span>
          Разрешаю отправлять {providerName} мой вопрос, агрегаты глюкозы,
          питания, инсулина, активности и цикла, а при разборе болюса — снимок
          выбранного расчёта.
        </span>
      </label>
      <p className="subtle-note">
        Отправка происходит при запросе анализа. Имя, email и свободные заметки
        дневника не включаются. Оплата запросов идёт через ваш аккаунт{" "}
        {providerName}.
      </p>
      <ErrorBox message={error} />
      {message && (
        <div className="success-box" role="status">
          <Check size={18} />
          {message}
        </div>
      )}
      <button className="primary full" type="submit" disabled={busy || !config}>
        {busy ? "Сохраняем…" : "Сохранить подключение"}
      </button>
      {currentKey && (
        <div className="form-actions">
          <button
            className="secondary"
            type="button"
            disabled={busy || dirty}
            onClick={() =>
              run(async () => {
                const result = await post("/ai/test");
                setConfig(await api("/ai/settings"));
                setMessage(
                  `${providerName}: ключ и модель работают. Тест использовал ${result.usage.total_tokens} токенов.`,
                );
              })
            }
          >
            Проверить подключение
          </button>
          <button
            className="text-button danger-text"
            type="button"
            disabled={busy}
            onClick={() =>
              run(async () => {
                await api("/ai/settings/key", { method: "DELETE" });
                setConfig({
                  ...config,
                  key_configured: false,
                  consent: false,
                  last_check: null,
                });
                setConsent(false);
                setMessage("Ключ удалён с сервера");
              })
            }
          >
            Удалить ключ
          </button>
        </div>
      )}
      {currentKey && (
        <p className="subtle-note">
          Проверка выполняет короткий запрос без данных дневника и использует
          токены. {dirty ? "Сначала сохраните изменённые настройки." : ""}
        </p>
      )}
      {!dirty && config?.last_check?.connected && (
        <div className="success-box">
          <Check size={18} />
          {providerName} · {config.last_check.model} · подключение проверено
        </div>
      )}
      {config && (
        <p className="subtle-note">
          Анализов: {config.requests} · использовано токенов:{" "}
          {decimal(config.total_tokens, 0)}
        </p>
      )}
    </form>
  );
}

export function AssistantView({
  calculationId,
  onSettings,
  onClearCalculation,
}: any) {
  const [question, setQuestion] = useState(""),
    [days, setDays] = useState(14),
    [config, setConfig] = useState<any>(null),
    [history, setHistory] = useState<any[]>([]),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  useEffect(() => {
    Promise.all([api("/ai/settings"), api("/ai/history")])
      .then(([c, h]) => {
        setConfig(c);
        setHistory(h);
      })
      .catch((e) => setError(e.message));
  }, []);
  useEffect(() => {
    if (calculationId)
      setQuestion(
        "Объясни компоненты этого расчёта болюса и какие данные стоит проверить.",
      );
  }, [calculationId]);
  const connected =
    config?.enabled && config?.key_configured && config?.consent;
  return (
    <div className="view-stack ai-view">
      <section className="card padded">
        <div className="section-title">
          <h2>
            <Sparkles size={22} /> Анализ дневника
          </h2>
          <button className="text-button" onClick={onSettings}>
            Подключение AI
          </button>
        </div>
        <p className="muted">
          Объяснения по вашим наблюдениям, питанию, активности и сохранённым
          расчётам.
        </p>
        {config && !connected && (
          <div className="info-box">
            Добавьте свой API-ключ и разрешите передачу агрегатов сервису{" "}
            {config.provider_name} в настройках подключения.
          </div>
        )}
        <div className="ai-prompts">
          {[
            "Какие наблюдения повторяются за этот период?",
            "Как связаны мои тренировки и глюкоза?",
            "На что обратить внимание в истории болюсов?",
          ].map((q) => (
            <button
              key={q}
              className="secondary"
              onClick={() => setQuestion(q)}
            >
              {q}
            </button>
          ))}
        </div>
        {calculationId && (
          <div className="info-box">
            Будет передан выбранный расчёт болюса.
            <button className="text-button" onClick={onClearCalculation}>
              Убрать
            </button>
          </div>
        )}
        <form
          className="form"
          onSubmit={async (e) => {
            e.preventDefault();
            setBusy(true);
            setError("");
            try {
              const r = await post("/ai/chat", {
                question,
                days,
                calculation_id: calculationId || null,
              });
              setHistory((h) => [r, ...h]);
              setQuestion("");
              setConfig(await api("/ai/settings"));
            } catch (e) {
              setError((e as Error).message);
            } finally {
              setBusy(false);
            }
          }}
        >
          <Field label="Период анализа">
            <select
              value={days}
              onChange={(e) => setDays(Number(e.target.value))}
            >
              {[1, 7, 14, 30, 90].map((v) => (
                <option key={v} value={v}>
                  {v} дней
                </option>
              ))}
            </select>
          </Field>
          <Field label="Ваш вопрос">
            <textarea
              rows={3}
              required
              maxLength={2000}
              value={question}
              onChange={(e) => setQuestion(e.target.value)}
              placeholder="Например, что меняется после вечерних тренировок?"
            />
          </Field>
          <ErrorBox message={error} />
          <button
            className="primary full"
            disabled={!connected || busy || !question.trim()}
            type="submit"
          >
            <Send size={17} />
            {busy
              ? "Анализируем наблюдения…"
              : `Отправить в ${config?.provider_name || "AI"}`}
          </button>
        </form>
        {config && (
          <p className="subtle-note">
            {config.provider_name} · {config.model} · {config.total_tokens}{" "}
            токенов в сохранённых ответах
          </p>
        )}
      </section>
      {history.map((item) => (
        <article key={item.id} className="card padded ai-answer">
          <p className="eyebrow">
            AI-ответ · {new Date(item.created_at).toLocaleString("ru-RU")}
          </p>
          <h3>{item.question}</h3>
          <p>{item.response.summary}</p>
          {[
            ["observations", "Наблюдения"],
            ["possible_explanations", "Возможные объяснения"],
            ["questions", "Что уточнить"],
            ["safety_flags", "Ограничения данных"],
          ].map(
            ([key, label]) =>
              item.response[key]?.length > 0 && (
                <div key={key}>
                  <h4>{label}</h4>
                  <ul>
                    {item.response[key].map((text: string, i: number) => (
                      <li key={i}>{text}</li>
                    ))}
                  </ul>
                </div>
              ),
          )}
          <small className="subtle-note">
            {item.provider === "tokenn" ? "Tokenn" : "OpenAI"} · {item.model} ·
            вход: {item.usage.input_tokens} · ответ: {item.usage.output_tokens}{" "}
            токенов
          </small>
        </article>
      ))}
    </div>
  );
}
