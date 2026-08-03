"use client";

import {
  AlertTriangle,
  BellRing,
  CheckCircle2,
  Clock3,
  Loader2,
  PauseCircle,
  PlayCircle,
  Plus,
  Save,
} from "lucide-react";
import { FormEvent, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import {
  type MailReminderRule,
  type MailReminderTemplateKey,
  type MailReminderWorkspace,
} from "@/lib/mail-v2-contract";

type Notice = { tone: "success" | "error"; text: string } | null;

const templateLabels: Record<MailReminderTemplateKey, string> = {
  portal_access_reminder: "Portaaltoegang herinnering",
  size_fill_reminder: "Ontbrekende maten herinnering",
  size_review_reminder: "Matencontrole herinnering",
  payment_reminder: "Betalingsherinnering",
  pickup_reminder: "Afhaalherinnering",
};
const fieldClass = "mt-2 h-11 w-full rounded-lg border border-line bg-white px-3 text-sm text-ink outline-none transition focus:border-brand-500 focus:ring-2 focus:ring-brand-100 disabled:bg-slate-50 disabled:text-slate-400";
const dateFormatter = new Intl.DateTimeFormat("nl-NL", {
  dateStyle: "short",
  timeStyle: "short",
  timeZone: "Europe/Amsterdam",
});

type RuleForm = {
  seasonId: string;
  templateKey: MailReminderTemplateKey;
  internalName: string;
  firstDelayHours: number;
  frequencyHours: number;
  maximumDispatches: number;
  cooldownHours: number;
  endAt: string;
  quietStart: string;
  quietEnd: string;
};

function localDateTime(value: string | null) {
  if (!value) return "";
  const date = new Date(value);
  const parts = new Intl.DateTimeFormat("sv-SE", {
    timeZone: "Europe/Amsterdam",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);
  const part = (type: Intl.DateTimeFormatPartTypes) =>
    parts.find((entry) => entry.type === type)?.value ?? "";
  return `${part("year")}-${part("month")}-${part("day")}T${part("hour")}:${part("minute")}`;
}

function formForRule(
  rule: MailReminderRule | undefined,
  workspace: MailReminderWorkspace,
): RuleForm {
  if (rule) {
    return {
      seasonId: rule.seasonId,
      templateKey: rule.templateKey,
      internalName: rule.internalName,
      firstDelayHours: rule.firstDelayHours,
      frequencyHours: rule.frequencyHours,
      maximumDispatches: rule.maximumDispatches,
      cooldownHours: rule.cooldownHours,
      endAt: localDateTime(rule.endAt),
      quietStart: rule.quietStart,
      quietEnd: rule.quietEnd,
    };
  }
  return {
    seasonId: workspace.seasons.find((season) => season.status === "open")?.id
      ?? workspace.seasons[0]?.id
      ?? "",
    templateKey: "payment_reminder",
    internalName: "",
    firstDelayHours: 72,
    frequencyHours: 168,
    maximumDispatches: 4,
    cooldownHours: 24,
    endAt: "",
    quietStart: "21:00",
    quietEnd: "08:00",
  };
}

async function postRule(body: unknown) {
  const response = await fetch("/api/email/v2/reminders", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Duindorp-CSRF": "same-origin",
      "X-Correlation-ID": crypto.randomUUID(),
    },
    body: JSON.stringify(body),
  });
  const payload = await response.json() as Record<string, unknown> & {
    error?: string;
  };
  if (!response.ok) {
    throw new Error(payload.error ?? "De herinneringsregel kon niet worden verwerkt.");
  }
  return payload;
}

function StatusNotice({ notice }: { notice: Notice }) {
  if (!notice) return null;
  return (
    <div
      role={notice.tone === "error" ? "alert" : "status"}
      className={`mb-5 flex items-start gap-2 rounded-xl border p-4 text-xs ${
        notice.tone === "error"
          ? "border-red-100 bg-red-50 text-danger"
          : "border-emerald-100 bg-emerald-50 text-success"
      }`}
    >
      {notice.tone === "error"
        ? <AlertTriangle className="size-4 shrink-0" />
        : <CheckCircle2 className="size-4 shrink-0" />}
      {notice.text}
    </div>
  );
}

export function MailV2RemindersPanel({
  workspace,
}: {
  workspace: MailReminderWorkspace;
}) {
  const router = useRouter();
  const [selectedId, setSelectedId] = useState(
    workspace.rules[0]?.id ?? "new",
  );
  const selected = useMemo(
    () => workspace.rules.find((rule) => rule.id === selectedId),
    [selectedId, workspace.rules],
  );
  const [form, setForm] = useState<RuleForm>(
    formForRule(selected, workspace),
  );
  const [reason, setReason] = useState("");
  const [notice, setNotice] = useState<Notice>(null);
  const [busy, setBusy] = useState<"save" | "toggle" | null>(null);

  useEffect(() => {
    setForm(formForRule(selected, workspace));
    setReason("");
    setNotice(null);
  }, [selected, workspace]);

  function change<K extends keyof RuleForm>(key: K, value: RuleForm[K]) {
    setForm((current) => ({ ...current, [key]: value }));
  }

  async function save(event: FormEvent) {
    event.preventDefault();
    setBusy("save");
    setNotice(null);
    try {
      await postRule({
        action: "save",
        ruleId: selected?.id ?? null,
        seasonId: form.seasonId,
        templateKey: form.templateKey,
        expectedRevision: selected?.revision ?? null,
        config: {
          internalName: form.internalName,
          firstDelayHours: form.firstDelayHours,
          frequencyHours: form.frequencyHours,
          maximumDispatches: form.maximumDispatches,
          cooldownHours: form.cooldownHours,
          endAt: form.endAt ? new Date(form.endAt).toISOString() : null,
          quietStart: form.quietStart,
          quietEnd: form.quietEnd,
        },
      });
      setNotice({
        tone: "success",
        text: selected
          ? "Regel geversioneerd en uit veiligheid gedeactiveerd. Controleer en activeer opnieuw."
          : "Regel inactief aangemaakt. Controleer de doelgroep en activeer daarna expliciet.",
      });
      router.refresh();
    } catch (error) {
      setNotice({
        tone: "error",
        text: error instanceof Error
          ? error.message
          : "Opslaan van de herinneringsregel is mislukt.",
      });
    } finally {
      setBusy(null);
    }
  }

  async function toggle() {
    if (!selected) return;
    setBusy("toggle");
    setNotice(null);
    try {
      await postRule({
        action: "toggle",
        ruleId: selected.id,
        expectedRevision: selected.revision,
        active: !selected.active,
        reason,
      });
      setNotice({
        tone: "success",
        text: selected.active
          ? "Herinneringsregel is geaudit gepauzeerd."
          : "Herinneringsregel is geaudit geactiveerd.",
      });
      setReason("");
      router.refresh();
    } catch (error) {
      setNotice({
        tone: "error",
        text: error instanceof Error
          ? error.message
          : "De regelstatus kon niet worden gewijzigd.",
      });
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="grid gap-6 xl:grid-cols-[340px_minmax(0,1fr)]">
      <aside className="overflow-hidden rounded-xl border border-line bg-white shadow-card">
        <div className="border-b border-line p-5">
          <div className="flex items-start justify-between gap-3">
            <div>
              <p className="text-[10px] font-bold uppercase tracking-[0.12em] text-brand-500">
                Planner
              </p>
              <h2 className="mt-1 text-base font-bold text-brand-900">
                Herinneringsregels
              </h2>
            </div>
            <button
              type="button"
              onClick={() => setSelectedId("new")}
              className="inline-flex size-9 items-center justify-center rounded-lg bg-brand-700 text-white hover:bg-brand-800 focus:outline-none focus:ring-2 focus:ring-brand-300"
              aria-label="Nieuwe herinneringsregel"
            >
              <Plus className="size-4" />
            </button>
          </div>
          <p className="mt-2 text-[11px] leading-5 text-slate-500">
            Nieuwe en gewijzigde regels zijn altijd inactief. Verzending stopt
            automatisch zodra de actuele procesvoorwaarde niet meer geldt.
          </p>
        </div>
        <div className="divide-y divide-line">
          {workspace.rules.length === 0 && (
            <div className="p-5 text-xs text-slate-500">
              Nog geen herinneringsregels.
            </div>
          )}
          {workspace.rules.map((rule) => (
            <button
              key={rule.id}
              type="button"
              onClick={() => setSelectedId(rule.id)}
              className={`w-full p-4 text-left transition focus:outline-none focus:ring-2 focus:ring-inset focus:ring-brand-300 ${
                selectedId === rule.id ? "bg-brand-50" : "hover:bg-slate-50"
              }`}
            >
              <div className="flex items-center justify-between gap-3">
                <p className="truncate text-xs font-bold text-brand-900">
                  {rule.internalName}
                </p>
                <span className={`rounded-full px-2 py-1 text-[9px] font-bold uppercase ${
                  rule.active
                    ? "bg-emerald-100 text-success"
                    : "bg-slate-100 text-slate-500"
                }`}>
                  {rule.active ? "Actief" : "Inactief"}
                </span>
              </div>
              <p className="mt-1 text-[10px] text-slate-500">
                {templateLabels[rule.templateKey]}
              </p>
              <div className="mt-3 flex items-center justify-between text-[10px]">
                <span className="font-semibold text-brand-700">
                  Nu geschikt: {rule.dueNow}
                </span>
                <span className="text-slate-400">v{rule.revision}</span>
              </div>
            </button>
          ))}
        </div>
      </aside>

      <section className="rounded-xl border border-line bg-white p-6 shadow-card">
        <StatusNotice notice={notice} />
        <div className="flex flex-col gap-4 border-b border-line pb-5 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <p className="text-[10px] font-bold uppercase tracking-[0.12em] text-brand-500">
              Europe/Amsterdam
            </p>
            <h2 className="mt-1 text-lg font-bold text-brand-900">
              {selected ? "Regel bewerken" : "Nieuwe regel"}
            </h2>
            <p className="mt-1 text-xs text-slate-500">
              Stille uren, cooldown en stopvoorwaarden worden vlak vóór ieder
              enqueue-moment opnieuw server-side gecontroleerd.
            </p>
          </div>
          {selected && (
            <div className="grid grid-cols-2 gap-2 text-center text-[10px]">
              <div className="rounded-lg bg-brand-50 px-3 py-2">
                <p className="font-bold text-brand-900">{selected.dueNow}</p>
                <p className="text-brand-600">nu geschikt</p>
              </div>
              <div className="rounded-lg bg-slate-50 px-3 py-2">
                <p className="font-bold text-brand-900">
                  {selected.nextDueAt
                    ? dateFormatter.format(new Date(selected.nextDueAt))
                    : "Geen"}
                </p>
                <p className="text-slate-500">eerstvolgend</p>
              </div>
            </div>
          )}
        </div>

        <form onSubmit={save} className="mt-5">
          <div className="grid gap-4 md:grid-cols-2">
            <label className="text-xs font-semibold text-ink">
              Seizoen
              <select
                value={form.seasonId}
                onChange={(event) => change("seasonId", event.target.value)}
                disabled={Boolean(selected)}
                className={fieldClass}
                required
              >
                {workspace.seasons.map((season) => (
                  <option key={season.id} value={season.id}>
                    {season.name} · {season.status === "open" ? "open" : "gearchiveerd"}
                  </option>
                ))}
              </select>
            </label>
            <label className="text-xs font-semibold text-ink">
              Proces/template
              <select
                value={form.templateKey}
                onChange={(event) => change(
                  "templateKey",
                  event.target.value as MailReminderTemplateKey,
                )}
                disabled={Boolean(selected)}
                className={fieldClass}
              >
                {Object.entries(templateLabels).map(([key, label]) => (
                  <option key={key} value={key}>{label}</option>
                ))}
              </select>
            </label>
            <label className="text-xs font-semibold text-ink md:col-span-2">
              Interne naam
              <input
                value={form.internalName}
                onChange={(event) => change("internalName", event.target.value)}
                className={fieldClass}
                minLength={3}
                maxLength={120}
                required
              />
            </label>
            <NumberField label="Eerste vertraging (uren)" value={form.firstDelayHours} min={1} max={2160} onChange={(value) => change("firstDelayHours", value)} />
            <NumberField label="Frequentie (uren)" value={form.frequencyHours} min={1} max={2160} onChange={(value) => change("frequencyHours", value)} />
            <NumberField label="Maximaal aantal herinneringen" value={form.maximumDispatches} min={1} max={20} onChange={(value) => change("maximumDispatches", value)} />
            <NumberField label="Cooldown (uren)" value={form.cooldownHours} min={1} max={720} onChange={(value) => change("cooldownHours", value)} />
            <label className="text-xs font-semibold text-ink">
              Stille uren vanaf
              <input type="time" value={form.quietStart} onChange={(event) => change("quietStart", event.target.value)} className={fieldClass} required />
            </label>
            <label className="text-xs font-semibold text-ink">
              Stille uren tot
              <input type="time" value={form.quietEnd} onChange={(event) => change("quietEnd", event.target.value)} className={fieldClass} required />
            </label>
            <label className="text-xs font-semibold text-ink md:col-span-2">
              Einddatum (optioneel)
              <input type="datetime-local" value={form.endAt} onChange={(event) => change("endAt", event.target.value)} className={fieldClass} />
            </label>
          </div>
          <div className="mt-5 flex flex-wrap items-center justify-between gap-3 border-t border-line pt-5">
            <p className="max-w-xl text-[11px] leading-5 text-slate-500">
              Opslaan maakt de regel inactief. De teller ‘nu geschikt’ is een
              actuele doelgroepvoorvertoning zonder providerverkeer.
            </p>
            <button
              type="submit"
              disabled={busy !== null || workspace.seasons.length === 0}
              className="inline-flex h-10 items-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-bold text-white hover:bg-brand-800 disabled:opacity-50"
            >
              {busy === "save"
                ? <Loader2 className="size-4 animate-spin" />
                : <Save className="size-4" />}
              Veilig opslaan
            </button>
          </div>
        </form>

        {selected && (
          <div className="mt-6 rounded-xl border border-line bg-slate-50 p-5">
            <div className="flex items-start gap-3">
              <span className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-white text-brand-700">
                {selected.active
                  ? <PauseCircle className="size-5" />
                  : <PlayCircle className="size-5" />}
              </span>
              <div className="min-w-0 flex-1">
                <h3 className="text-sm font-bold text-brand-900">
                  {selected.active ? "Regel pauzeren" : "Regel activeren"}
                </h3>
                <p className="mt-1 text-[11px] leading-5 text-slate-500">
                  Vereist beheerders-MFA en een reden. Activeren vereist een
                  open seizoen, gepubliceerde template en bewezen producent.
                </p>
                <label className="mt-3 block text-xs font-semibold text-ink">
                  Reden
                  <input value={reason} onChange={(event) => setReason(event.target.value)} className={fieldClass} minLength={3} maxLength={240} />
                </label>
                <div className="mt-4 flex flex-wrap items-center justify-between gap-3">
                  <p className="inline-flex items-center gap-2 text-[10px] text-slate-500">
                    <Clock3 className="size-3.5" />
                    Laatste run: {selected.lastRunAt
                      ? `${dateFormatter.format(new Date(selected.lastRunAt))} · ${selected.lastRunStatus}`
                      : "nog niet uitgevoerd"}
                  </p>
                  <button
                    type="button"
                    onClick={toggle}
                    disabled={busy !== null || reason.trim().length < 3}
                    className={`inline-flex h-10 items-center gap-2 rounded-lg px-4 text-xs font-bold text-white disabled:opacity-50 ${
                      selected.active
                        ? "bg-slate-700 hover:bg-slate-800"
                        : "bg-emerald-700 hover:bg-emerald-800"
                    }`}
                  >
                    {busy === "toggle"
                      ? <Loader2 className="size-4 animate-spin" />
                      : <BellRing className="size-4" />}
                    {selected.active ? "Pauzeren" : "Activeren"}
                  </button>
                </div>
              </div>
            </div>
          </div>
        )}
      </section>
    </div>
  );
}

function NumberField({
  label,
  value,
  min,
  max,
  onChange,
}: {
  label: string;
  value: number;
  min: number;
  max: number;
  onChange: (value: number) => void;
}) {
  return (
    <label className="text-xs font-semibold text-ink">
      {label}
      <input
        type="number"
        value={value}
        min={min}
        max={max}
        onChange={(event) => onChange(event.currentTarget.valueAsNumber)}
        className={fieldClass}
        required
      />
    </label>
  );
}
