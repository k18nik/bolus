"use client";
import * as Dialog from "@radix-ui/react-dialog";
import {
  X,
  LoaderCircle,
  Plus,
  Droplet,
  Syringe,
  Utensils,
  Activity,
  Moon,
  FileText,
  ChevronRight,
} from "lucide-react";
import { decimal } from "@/services/api";
export function Modal({
  title,
  description,
  children,
  onClose,
  wide = false,
}: {
  title: string;
  description?: string;
  children: React.ReactNode;
  onClose: () => void;
  wide?: boolean;
}) {
  return (
    <Dialog.Root open onOpenChange={(v) => !v && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="modal-overlay" />
        <Dialog.Content
          className={"modal " + (wide ? "wide" : "")}
          aria-describedby={description ? "modal-description" : undefined}
        >
          <div className="modal-heading">
            <div>
              <Dialog.Title>{title}</Dialog.Title>
              {description && (
                <Dialog.Description id="modal-description">
                  {description}
                </Dialog.Description>
              )}
            </div>
            <Dialog.Close className="icon-button" aria-label="Закрыть">
              <X size={21} />
            </Dialog.Close>
          </div>
          {children}
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
export function Field({
  label,
  children,
  hint,
}: {
  label: string;
  children: React.ReactNode;
  hint?: string;
}) {
  return (
    <label className="field">
      <span>{label}</span>
      {children}
      {hint && <small>{hint}</small>}
    </label>
  );
}
export function Submit({
  busy = false,
  children,
}: {
  busy?: boolean;
  children: React.ReactNode;
}) {
  return (
    <button className="primary full" disabled={busy} type="submit">
      {busy ? (
        <>
          <LoaderCircle className="spin" size={18} />
          Сохраняем…
        </>
      ) : (
        children
      )}
    </button>
  );
}
export function ErrorBox({ message }: { message?: string }) {
  return message ? (
    <div className="error-box" role="alert">
      {message}
    </div>
  ) : null;
}
export function Empty({
  title = "Пока нет записей",
  text = "Начните с одной записи — она появится здесь.",
  action,
}: {
  title?: string;
  text?: string;
  action?: () => void;
}) {
  return (
    <div className="empty">
      <span className="empty-icon">
        <BookIcon />
      </span>
      <h3>{title}</h3>
      <p>{text}</p>
      {action && (
        <button className="primary" onClick={action}>
          <Plus size={17} />
          Добавить запись
        </button>
      )}
    </div>
  );
}
function BookIcon() {
  return <FileText size={26} />;
}
export const eventIcons: any = {
  glucose: Droplet,
  insulin: Syringe,
  meal: Utensils,
  activity: Activity,
  activity_summary: Activity,
  cycle: Moon,
  note: FileText,
};
export function EventRow({
  entry,
  user,
  onClick,
}: {
  entry: any;
  user: any;
  onClick?: () => void;
}) {
  const e = entry,
    d = e.data;
  const Icon = eventIcons[e.kind] || FileText;
  const title =
    e.kind === "glucose"
      ? "Глюкоза"
      : e.kind === "insulin"
        ? d.insulin_name || "Инсулин"
        : d.name || "Заметка";
  const note =
    e.kind === "glucose"
      ? d.source === "manual"
        ? "Вручную"
        : d.source
      : e.kind === "insulin"
        ? (
            {
              meal: "На еду",
              correction: "Коррекция",
              meal_and_correction: "Еда и коррекция",
              basal: "Базальный",
              manual: "Ручная запись",
            } as any
          )[d.purpose]
        : e.kind === "meal"
          ? d.items?.map((i: any) => i.name_snapshot).join(", ")
          : e.kind === "activity"
            ? d.source === "apple_health"
              ? "Apple «Здоровье»"
              : "Активность"
            : e.kind === "activity_summary"
              ? "Apple «Здоровье» · дневная сводка"
              : d.note;
  const value =
    e.kind === "glucose"
      ? decimal(d.value_mmol * (user.glucose_unit === "mg/dL" ? 18 : 1))
      : e.kind === "insulin"
        ? decimal(d.units)
        : e.kind === "meal"
          ? decimal(d.total_carbs)
          : e.kind === "activity"
            ? d.duration_minutes
            : e.kind === "activity_summary"
              ? decimal(
                  d.steps ?? d.exercise_minutes ?? d.active_energy ?? null,
                )
              : "";
  const unit =
    e.kind === "glucose"
      ? user.glucose_unit === "mg/dL"
        ? "мг/дл"
        : "ммоль/л"
      : e.kind === "insulin"
        ? "ЕД"
        : e.kind === "meal"
          ? "г углеводов"
          : e.kind === "activity_summary"
            ? d.steps != null
              ? "шагов"
              : d.exercise_minutes != null
                ? "мин"
                : d.active_energy != null
                  ? "ккал"
                  : ""
            : e.kind === "activity"
              ? "мин"
              : "";
  return (
    <button className="event event-button" onClick={onClick}>
      <time>
        {new Date(e.occurred_at).toLocaleTimeString("ru-RU", {
          timeZone: user.timezone,
          hour: "2-digit",
          minute: "2-digit",
        })}
      </time>
      <span className={"event-icon " + (e.kind === "meal" ? "food" : e.kind)}>
        <Icon size={19} />
      </span>
      <div className="event-description">
        <b>{title}</b>
        <small>{note}</small>
      </div>
      <div className="event-value">
        <b>{value}</b>
        <small>{unit}</small>
      </div>
      <ChevronRight size={16} />
    </button>
  );
}
