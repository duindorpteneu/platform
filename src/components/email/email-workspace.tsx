"use client";

import { AlertTriangle, BellRing, Check, CheckCircle2, Clock3, Eye, FileText, Loader2, Mail, Palette, RefreshCw, Search, Send, ShieldCheck, Users } from "lucide-react";
import { FormEvent, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { emailTemplateLabels, type BulkEmailTemplateKey, type EmailWorkspace as Workspace } from "@/lib/email-contract";
import {
  mailV2CampaignConfirmSchema,
  mailV2CampaignPreviewSchema,
  type MailV2CampaignConfirm,
  type MailV2CampaignPreview,
  type MailV2CampaignTemplateKey,
  type MailV2CampaignWorkspace,
  type MailV2CutoverSnapshot,
  type MailV2Workspace,
  type MailReminderWorkspace,
} from "@/lib/mail-v2-contract";
import {
  MailV2BrandingPanel,
  MailV2CutoverPanel,
  MailV2TemplatesPanel,
} from "@/components/email/mail-v2-workspace";
import { MailV2RemindersPanel } from "@/components/email/mail-v2-reminders-panel";

type Tab = "templates" | "branding" | "reminders" | "bulk" | "delivery";
type Notice = { tone: "success" | "error"; text: string } | null;
type Preview = { subject: string; text: string };
type CampaignTarget = {
  targetId: string;
  memberName: string;
  team: string;
  season: string;
  relationNumber: string | null;
  amountDueCents: number | null;
  statusDetail: string | null;
};

const fieldClass = "mt-2 w-full rounded-lg border border-line bg-white px-3 text-sm text-ink outline-none transition focus:border-brand-500 focus:ring-2 focus:ring-brand-100 disabled:bg-slate-50 disabled:text-slate-400";
const dateFormatter = new Intl.DateTimeFormat("nl-NL", { dateStyle: "short", timeStyle: "short" });
const emailJobLabels: Record<string, string> = {
  ...emailTemplateLabels,
  partial_pickup: "Deel van pakket afgehaald",
  package_complete: "Pakket volledig afgehaald",
};
const campaignTemplateLabels: Record<MailV2CampaignTemplateKey, string> = {
  portal_access_reminder: "Herinnering portaaltoegang",
  size_fill_request: "Verzoek ontbrekende maten",
  size_fill_reminder: "Herinnering ontbrekende maten",
  size_review_request: "Verzoek maten controleren",
  size_review_reminder: "Herinnering maten controleren",
  payment_request: "Betaalverzoek",
  payment_reminder: "Betalingsherinnering",
  available_payment_required: "Voorraad beschikbaar, betaling nodig",
  pickup_reminder: "Afhaalherinnering",
  out_of_stock: "Tijdelijk niet leverbaar",
};

async function postJson(path: string, body: unknown) {
  const response = await fetch(path, { method: "POST", headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin", "X-Correlation-ID": crypto.randomUUID() }, body: JSON.stringify(body) });
  const payload = await response.json() as Record<string, unknown> & { error?: string };
  if (!response.ok) throw new Error(payload.error ?? "De aanvraag kon niet worden verwerkt.");
  return payload;
}

function StatusNotice({ notice }: { notice: Notice }) {
  if (!notice) return null;
  return <div role={notice.tone === "error" ? "alert" : "status"} className={`mb-6 flex items-start gap-2 rounded-xl border p-4 text-xs ${notice.tone === "error" ? "border-red-100 bg-red-50 text-danger" : "border-emerald-100 bg-emerald-50 text-success"}`}>
    {notice.tone === "error" ? <AlertTriangle className="size-4 shrink-0" /> : <CheckCircle2 className="size-4 shrink-0" />}{notice.text}
  </div>;
}

export function EmailWorkspace({
  workspace,
  mailV2Workspace,
  mailV2Cutover,
  campaignWorkspace,
  reminderWorkspace,
  canManageTemplates,
  emailEnabled,
}: {
  workspace: Workspace;
  mailV2Workspace?: MailV2Workspace;
  mailV2Cutover?: MailV2CutoverSnapshot;
  campaignWorkspace: MailV2CampaignWorkspace;
  reminderWorkspace?: MailReminderWorkspace;
  canManageTemplates: boolean;
  emailEnabled: boolean;
}) {
  const [tab, setTab] = useState<Tab>(canManageTemplates ? "templates" : "bulk");
  const failed = workspace.jobs.filter((job) => ["failed", "delivery_uncertain"].includes(job.status) || ["bounced", "dropped", "failed"].includes(job.deliveryStatus ?? "")).length;
  const queued = workspace.jobs.filter((job) => ["queued", "processing", "retry"].includes(job.status)).length;
  const delivered = workspace.jobs.filter((job) => job.deliveryStatus === "delivered").length;
  const activeTemplateCount = mailV2Workspace
    ? mailV2Workspace.templates.filter((template) => template.published).length
    : workspace.templates.filter((template) => template.active).length;
  const navigation = canManageTemplates
    ? ([
      { id: "templates", label: "Templates", icon: FileText },
      { id: "branding", label: "Branding", icon: Palette },
      { id: "reminders", label: "Herinneringen", icon: BellRing },
      { id: "bulk", label: "Bulkmail", icon: Users },
      { id: "delivery", label: "Verzending", icon: Send },
    ] as const)
    : ([
      { id: "bulk", label: "Bulkmail", icon: Users },
      { id: "delivery", label: "Verzending", icon: Send },
    ] as const);

  return <div className="mx-auto max-w-[1400px]">
    <header className="flex flex-col gap-5 lg:flex-row lg:items-end lg:justify-between">
      <div><p className="text-xs font-semibold uppercase tracking-[0.12em] text-brand-500">Transactionele communicatie</p><h1 className="mt-2 text-[30px] font-bold tracking-[-0.04em] text-brand-900 md:text-[34px]">E-mailcentrum</h1><p className="mt-2 max-w-2xl text-sm leading-6 text-slate-500">Beheer veilige clubtemplates, stel handmatige bulkacties samen en volg de duurzame verzendwachtrij.</p></div>
      <div className={`inline-flex h-10 items-center gap-2 self-start rounded-lg border px-3 text-xs font-bold ${emailEnabled ? "border-emerald-200 bg-emerald-50 text-success" : "border-amber-200 bg-amber-50 text-amber-800"}`}><span className={`size-2 rounded-full ${emailEnabled ? "bg-emerald-500" : "bg-amber-500"}`} />{emailEnabled ? "Verzending actief" : "Verzending gepauzeerd"}</div>
    </header>

    <section className="mt-6 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
      <Metric icon={FileText} label="Actieve templates" value={String(activeTemplateCount)} detail="Canonieke berichttypen" />
      <Metric icon={Clock3} label="In wachtrij" value={String(queued)} detail="Inclusief veilige retries" />
      <Metric icon={CheckCircle2} label="Afgeleverd" value={String(delivered)} detail="Recente operationele jobs" />
      <Metric icon={AlertTriangle} label="Aandacht nodig" value={String(failed)} detail="Failed, bounce of drop" tone={failed ? "danger" : "normal"} />
    </section>

    <nav className="mt-6 flex gap-1 overflow-x-auto rounded-xl border border-line bg-white p-1 shadow-card" aria-label="E-mailonderdelen">
      {navigation.map((entry) => <button key={entry.id} type="button" onClick={() => setTab(entry.id)} className={`inline-flex h-10 min-w-fit flex-1 items-center justify-center gap-2 rounded-lg px-4 text-xs font-bold transition ${tab === entry.id ? "bg-brand-700 text-white" : "text-slate-500 hover:bg-slate-50 hover:text-brand-900"}`}><entry.icon className="size-4" />{entry.label}</button>)}
    </nav>

    <div className="mt-6">
      {tab === "templates" && canManageTemplates && (
        mailV2Workspace && mailV2Cutover
          ? (
            <>
              <MailV2CutoverPanel snapshot={mailV2Cutover} />
              <MailV2TemplatesPanel workspace={mailV2Workspace} />
            </>
          )
          : <TemplatesPanel workspace={workspace} />
      )}
      {tab === "branding" && canManageTemplates && mailV2Workspace && (
        <MailV2BrandingPanel workspace={mailV2Workspace} />
      )}
      {tab === "reminders" && canManageTemplates && reminderWorkspace && (
        <MailV2RemindersPanel workspace={reminderWorkspace} />
      )}
      {tab === "bulk" && (
        campaignWorkspace.cutoverStarted
          ? (
            <MailV2CampaignPanel
              campaignWorkspace={campaignWorkspace}
              emailEnabled={emailEnabled}
            />
          )
          : <BulkPanel workspace={workspace} emailEnabled={emailEnabled} />
      )}
      {tab === "delivery" && <DeliveryPanel workspace={workspace} />}
    </div>
  </div>;
}

function Metric({ icon: Icon, label, value, detail, tone = "normal" }: { icon: typeof Mail; label: string; value: string; detail: string; tone?: "normal" | "danger" }) {
  return <div className="rounded-xl border border-line bg-white p-5 shadow-card"><div className="flex items-center justify-between"><p className="text-[10px] font-bold uppercase tracking-[0.1em] text-slate-400">{label}</p><span className={`flex size-8 items-center justify-center rounded-lg ${tone === "danger" ? "bg-red-50 text-danger" : "bg-brand-50 text-brand-700"}`}><Icon className="size-4" /></span></div><p className={`mt-3 text-2xl font-bold ${tone === "danger" ? "text-danger" : "text-brand-900"}`}>{value}</p><p className="mt-1 text-[11px] text-slate-400">{detail}</p></div>;
}

function TemplatesPanel({ workspace }: { workspace: Workspace }) {
  const router = useRouter();
  const [selectedId, setSelectedId] = useState(workspace.templates[0]?.id ?? "");
  const template = workspace.templates.find((candidate) => candidate.id === selectedId) ?? workspace.templates[0];
  const [subject, setSubject] = useState(template?.subjectSource ?? "");
  const [body, setBody] = useState(template?.bodySource ?? "");
  const [preview, setPreview] = useState<Preview | null>(null);
  const [notice, setNotice] = useState<Notice>(null);
  const [busy, setBusy] = useState<"preview" | "save" | null>(null);
  useEffect(() => { setSubject(template?.subjectSource ?? ""); setBody(template?.bodySource ?? ""); setPreview(null); setNotice(null); }, [template]);
  if (!template) return <Empty icon={FileText} title="Geen templates beschikbaar" text="De beschikbare templates zijn nog niet veilig geladen." />;

  async function previewTemplate() {
    setBusy("preview"); setNotice(null);
    try {
      const response = await postJson("/api/email/templates/preview", { templateId: template.id, subjectSource: subject, bodySource: body });
      setPreview({ subject: String(response.subject), text: String(response.text) });
    } catch (error) { setNotice({ tone: "error", text: error instanceof Error ? error.message : "Voorvertoning mislukt." }); }
    finally { setBusy(null); }
  }

  async function save(event: FormEvent) {
    event.preventDefault(); setBusy("save"); setNotice(null);
    try {
      await postJson("/api/email/templates", { templateId: template.id, subjectSource: subject, bodySource: body, expectedVersion: template.version });
      setNotice({ tone: "success", text: "Template opgeslagen, geversioneerd en geaudit." });
      router.refresh();
    } catch (error) { setNotice({ tone: "error", text: error instanceof Error ? error.message : "Opslaan mislukt." }); }
    finally { setBusy(null); }
  }

  return <div className="grid items-start gap-6 xl:grid-cols-[320px_minmax(0,1fr)]">
    <aside className="overflow-hidden rounded-xl border border-line bg-white shadow-card"><div className="border-b border-line px-5 py-4"><h2 className="text-sm font-bold text-brand-900">Berichttypen</h2><p className="mt-1 text-[11px] text-slate-400">Rolgebonden templatecatalogus</p></div><div className="divide-y divide-line">{workspace.templates.map((entry) => <button key={entry.id} type="button" onClick={() => setSelectedId(entry.id)} className={`flex w-full items-center gap-3 px-4 py-4 text-left transition ${entry.id === template.id ? "bg-brand-50" : "hover:bg-slate-50"}`}><span className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-white text-brand-700 shadow-sm"><Mail className="size-4" /></span><span className="min-w-0 flex-1"><span className="block truncate text-xs font-bold text-brand-900">{emailTemplateLabels[entry.key]}</span><span className="mt-1 block text-[10px] text-slate-400">Versie {entry.version} · {entry.active ? "Actief" : "Inactief"}</span></span></button>)}</div></aside>
    <div>
      <StatusNotice notice={notice} />
      <form onSubmit={save} className="rounded-xl border border-line bg-white p-6 shadow-card">
        <div className="flex flex-col gap-3 border-b border-line pb-5 sm:flex-row sm:items-start sm:justify-between"><div><p className="text-[10px] font-bold uppercase tracking-[0.12em] text-brand-500">Template bewerken</p><h2 className="mt-1 text-lg font-bold text-brand-900">{emailTemplateLabels[template.key]}</h2><p className="mt-1 text-xs text-slate-500">Alleen platte tekst en toegestane shortcodes; HTML en scripts worden geweigerd.</p></div><span className="rounded-full bg-slate-100 px-2.5 py-1 text-[10px] font-bold text-slate-500">v{template.version}</span></div>
        {template.key === "verification_code" && <div className="mt-5 flex gap-3 rounded-xl border border-brand-100 bg-brand-50 p-4 text-xs leading-5 text-brand-900"><ShieldCheck className="mt-0.5 size-4 shrink-0 text-brand-700" /><p>Gebruik <span className="font-mono font-bold">{"{{verificatiecode}}"}</span> voor de zescijferige code. Een echte code wordt alleen tijdens directe verzending ingevuld en nooit in de template, mailqueue of auditlog opgeslagen.</p></div>}
        <fieldset disabled={Boolean(busy)} className="mt-5 space-y-4"><label className="block text-xs font-semibold text-ink">Onderwerp<input className={`${fieldClass} h-11`} value={subject} onChange={(event) => setSubject(event.target.value)} maxLength={180} required /></label><label className="block text-xs font-semibold text-ink">Berichttekst<textarea className={`${fieldClass} min-h-52 py-3 leading-6`} value={body} onChange={(event) => setBody(event.target.value)} maxLength={10_000} required /></label></fieldset>
        <div className="mt-5"><p className="text-[10px] font-bold uppercase tracking-[0.1em] text-slate-400">Toegestane shortcodes</p><div className="mt-2 flex flex-wrap gap-2">{template.allowedShortcodes.map((code) => <button key={code} type="button" onClick={() => setBody((value) => `${value}${value.endsWith(" ") || !value ? "" : " "}${code}`)} className="rounded-md border border-line bg-slate-50 px-2 py-1 font-mono text-[10px] text-brand-700 hover:border-brand-300">{code}</button>)}</div></div>
        <div className="mt-6 flex flex-col-reverse gap-2 border-t border-line pt-5 sm:flex-row sm:justify-end"><button type="button" onClick={() => void previewTemplate()} disabled={Boolean(busy)} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-line px-4 text-xs font-bold text-brand-700 hover:border-brand-300 disabled:opacity-50">{busy === "preview" ? <Loader2 className="size-4 animate-spin" /> : <Eye className="size-4" />} Fictief voorbeeld</button><button type="submit" disabled={Boolean(busy)} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-bold text-white hover:bg-brand-900 disabled:opacity-50">{busy === "save" ? <Loader2 className="size-4 animate-spin" /> : <Check className="size-4" />} Template opslaan</button></div>
      </form>
      {preview && <section className="mt-6 rounded-xl border border-line bg-white p-6 shadow-card"><div className="flex items-center justify-between"><div><p className="text-[10px] font-bold uppercase tracking-[0.1em] text-brand-500">Fictieve voorvertoning</p><h3 className="mt-1 text-sm font-bold text-brand-900">Geen echte ledengegevens gebruikt</h3></div><Eye className="size-5 text-brand-500" /></div><div className="mt-4 rounded-lg border border-line bg-slate-50 p-4"><p className="text-xs font-bold text-brand-900">{preview.subject}</p><p className="mt-3 whitespace-pre-wrap text-xs leading-6 text-slate-600">{preview.text}</p></div></section>}
    </div>
  </div>;
}

function MailV2CampaignPanel({
  campaignWorkspace,
  emailEnabled,
}: {
  campaignWorkspace: MailV2CampaignWorkspace;
  emailEnabled: boolean;
}) {
  const router = useRouter();
  const firstTemplate = campaignWorkspace.allowedTemplates[0];
  const [templateKey, setTemplateKey] = useState<
    MailV2CampaignTemplateKey | ""
  >(firstTemplate ?? "");
  const portalMode = templateKey === "portal_access_reminder";
  const targets = useMemo<CampaignTarget[]>(
    () => portalMode
      ? campaignWorkspace.portalTargets.map((target) => ({
        targetId: target.memberSeasonId,
        memberName: target.memberName,
        team: target.team,
        season: target.season,
        relationNumber: null,
        amountDueCents: null,
        statusDetail: target.reminderEligible
          ? "Sinds activatie nog niet gebruikt"
          : "Sinds activatie gebruikt",
      }))
      : campaignWorkspace.orderTargets.map((order) => ({
        targetId: order.orderId,
        memberName: order.memberName,
        team: order.team,
        season: order.season,
        relationNumber: order.relationNumber,
        amountDueCents: order.amountDueCents,
        statusDetail: null,
      })),
    [
      campaignWorkspace.orderTargets,
      campaignWorkspace.portalTargets,
      portalMode,
    ],
  );
  const seasons = useMemo(
    () => [...new Set(targets.map((target) => target.season))]
      .sort((left, right) => left.localeCompare(right, "nl-NL")),
    [targets],
  );
  const [season, setSeason] = useState("");
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [preview, setPreview] = useState<MailV2CampaignPreview | null>(null);
  const [confirmation, setConfirmation] = useState<
    MailV2CampaignConfirm | null
  >(null);
  const [notice, setNotice] = useState<Notice>(null);
  const [busy, setBusy] = useState<"preview" | "confirm" | null>(null);
  const normalizedQuery = query.trim().toLocaleLowerCase("nl-NL");
  const visible = useMemo(
    () => targets.filter((target) => (
      target.season === season
      && `${target.memberName} ${target.relationNumber ?? ""} ${target.team}`
        .toLocaleLowerCase("nl-NL")
        .includes(normalizedQuery)
    )),
    [normalizedQuery, season, targets],
  );
  const allVisibleSelected = visible.length > 0
    && visible.every((target) => selected.has(target.targetId));

  useEffect(() => {
    setSeason((current) => (
      seasons.includes(current) ? current : (seasons[0] ?? "")
    ));
  }, [seasons]);

  useEffect(() => {
    setSelected(new Set());
    setPreview(null);
    setConfirmation(null);
    setNotice(null);
  }, [season, templateKey]);

  function toggle(targetId: string) {
    setPreview(null);
    setConfirmation(null);
    setSelected((current) => {
      const next = new Set(current);
      if (next.has(targetId)) {
        next.delete(targetId);
      } else if (next.size < 2_000) {
        next.add(targetId);
      }
      return next;
    });
  }

  function toggleVisible(checked: boolean) {
    setPreview(null);
    setConfirmation(null);
    setSelected((current) => {
      const next = new Set(current);
      if (!checked) {
        visible.forEach((target) => next.delete(target.targetId));
        return next;
      }
      for (const target of visible) {
        if (next.size >= 2_000) break;
        next.add(target.targetId);
      }
      return next;
    });
  }

  async function makePreview() {
    if (!templateKey) return;
    setBusy("preview");
    setNotice(null);
    setConfirmation(null);
    try {
      const response = await postJson("/api/email/v2/campaigns", {
        action: "preview",
        templateKey,
        targetIds: [...selected],
        requestId: crypto.randomUUID(),
      });
      setPreview(mailV2CampaignPreviewSchema.parse(response));
    } catch (error) {
      setNotice({
        tone: "error",
        text: error instanceof Error
          ? error.message
          : "De campagnepreflight is mislukt.",
      });
    } finally {
      setBusy(null);
    }
  }

  async function confirm() {
    if (!preview) return;
    setBusy("confirm");
    setNotice(null);
    try {
      const response = await postJson("/api/email/v2/campaigns", {
        action: "confirm",
        preflightId: preview.preflightId,
        expectedRevision: preview.eligibilityRevision,
        requestId: crypto.randomUUID(),
      });
      const parsed = mailV2CampaignConfirmSchema.parse(response);
      setConfirmation(parsed);
      setNotice({
        tone: "success",
        text: `${parsed.eventCount.toLocaleString("nl-NL")} actuele gebeurtenissen zijn voor ${parsed.parentGroupCount.toLocaleString("nl-NL")} geconsolideerde oudergroep(en) klaargezet.`,
      });
      setSelected(new Set());
      setPreview(null);
      router.refresh();
    } catch (error) {
      setNotice({
        tone: "error",
        text: error instanceof Error
          ? error.message
          : "De campagne kon niet veilig worden bevestigd.",
      });
    } finally {
      setBusy(null);
    }
  }

  if (!firstTemplate) {
    return (
      <Empty
        icon={ShieldCheck}
        title="Nog geen campagneprocessen beschikbaar"
        text="Publiceer eerst de vereiste templates en rond de server-side producenten af."
      />
    );
  }

  return (
    <div className="grid items-start gap-6 xl:grid-cols-[minmax(0,1fr)_400px]">
      <section className="overflow-hidden rounded-xl border border-line bg-white shadow-card">
        <div className="border-b border-line p-6">
          <div className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <p className="text-[10px] font-bold uppercase tracking-[0.12em] text-brand-500">
                Server-side doelgroepcontrole
              </p>
              <h2 className="mt-1 text-lg font-bold text-brand-900">
                Handmatige campagne
              </h2>
              <p className="mt-1 max-w-xl text-xs leading-5 text-slate-500">
                De preflight classificeert iedere keuze als geschikt, overgeslagen
                of geblokkeerd. Gedeelde ouderaccounts ontvangen per run één
                geconsolideerd bericht.
              </p>
            </div>
            <div className="grid gap-3 sm:grid-cols-2">
              <label className="text-xs font-semibold text-ink">
                Seizoen
                <select
                  value={season}
                  onChange={(event) => setSeason(event.target.value)}
                  className={`${fieldClass} h-10 min-w-44`}
                >
                  {seasons.map((entry) => (
                    <option key={entry} value={entry}>{entry}</option>
                  ))}
                </select>
              </label>
              <label className="text-xs font-semibold text-ink">
                Berichttype
                <select
                  value={templateKey}
                  onChange={(event) => setTemplateKey(
                    event.target.value as MailV2CampaignTemplateKey,
                  )}
                  className={`${fieldClass} h-10 min-w-64`}
                >
                  {campaignWorkspace.allowedTemplates.map((entry) => (
                    <option key={entry} value={entry}>
                      {campaignTemplateLabels[entry]}
                    </option>
                  ))}
                </select>
              </label>
            </div>
          </div>
          <div className="relative mt-5">
            <Search className="absolute left-3 top-3 size-4 text-slate-400" />
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder={portalMode
                ? "Zoek op naam of team"
                : "Zoek op naam, relatienummer of team"}
              className="h-10 w-full rounded-lg border border-line pl-9 pr-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100"
            />
          </div>
        </div>
        {visible.length === 0 ? (
          <Empty
            icon={Users}
            title="Geen doelgroepen in deze selectie"
            text={query
              ? "Geen resultaat binnen seizoen en zoekfilter."
              : portalMode
                ? "Dit seizoen bevat nog geen selecteerbare lid-seizoenen."
                : "Dit seizoen bevat nog geen selecteerbare pakketbestellingen."}
          />
        ) : (
          <>
            <div className="flex items-center justify-between border-b border-line bg-slate-50/60 px-6 py-3">
              <label className="flex items-center gap-2 text-[11px] font-bold text-slate-600">
                <input
                  type="checkbox"
                  checked={allVisibleSelected}
                  onChange={(event) => toggleVisible(event.target.checked)}
                  className="size-4 accent-brand-700"
                />
                Selecteer zichtbare ({visible.length})
              </label>
              <span className="text-[11px] font-bold text-brand-700">
                {selected.size.toLocaleString("nl-NL")} / 2.000 geselecteerd
              </span>
            </div>
            <div className="max-h-[560px] divide-y divide-line overflow-y-auto">
              {visible.map((target) => (
                <label
                  key={target.targetId}
                  className="flex cursor-pointer items-center gap-4 px-6 py-4 hover:bg-slate-50"
                >
                  <input
                    type="checkbox"
                    checked={selected.has(target.targetId)}
                    onChange={() => toggle(target.targetId)}
                    className="size-4 shrink-0 accent-brand-700"
                  />
                  <span className="min-w-0 flex-1">
                    <span className="block truncate text-xs font-bold text-brand-900">
                      {target.memberName}
                    </span>
                    <span className="mt-1 block text-[10px] text-slate-400">
                      {target.relationNumber
                        ? `${target.relationNumber} · `
                        : ""}
                      {target.team}
                    </span>
                  </span>
                  <span className="text-right text-[10px] font-semibold text-slate-500">
                    {target.amountDueCents === null
                      ? target.statusDetail
                      : new Intl.NumberFormat("nl-NL", {
                        style: "currency",
                        currency: "EUR",
                      }).format(target.amountDueCents / 100)}
                  </span>
                </label>
              ))}
            </div>
          </>
        )}
      </section>

      <aside className="space-y-6">
        <StatusNotice notice={notice} />
        <section className="rounded-xl border border-line bg-white p-6 shadow-card">
          <div className="flex items-center gap-3">
            <span className="flex size-10 items-center justify-center rounded-xl bg-brand-50 text-brand-700">
              <ShieldCheck className="size-5" />
            </span>
            <div>
              <h2 className="text-sm font-bold text-brand-900">
                Preflight en bevestiging
              </h2>
              <p className="mt-1 text-[11px] text-slate-400">
                Actorgebonden en tien minuten geldig
              </p>
            </div>
          </div>
          {(!emailEnabled || !campaignWorkspace.featureEnabled) && (
            <div className="mt-4 rounded-lg border border-amber-200 bg-amber-50 p-3 text-[11px] leading-5 text-amber-800">
              Verzending staat gepauzeerd. Bevestigde events blijven duurzaam
              wachten en veroorzaken nu geen providerverkeer.
            </div>
          )}
          {preview ? (
            <div className="mt-5 space-y-4">
              <div className="grid grid-cols-2 gap-2">
                <CampaignMetric label="Geschikt" value={preview.eligibleTargetCount} />
                <CampaignMetric label="Oudergroepen" value={preview.parentGroupCount} />
                <CampaignMetric label="Overgeslagen" value={preview.skippedTargetCount} />
                <CampaignMetric label="Geblokkeerd" value={preview.blockedTargetCount} />
              </div>
              {preview.preview && (
                <div className="rounded-lg border border-brand-100 bg-brand-50 p-4">
                  <p className="text-[10px] font-bold uppercase tracking-[0.1em] text-brand-500">
                    Exacte gepubliceerde revisie · representatieve oudergroep
                  </p>
                  <p className="mt-2 text-xs font-bold text-brand-900">
                    {preview.preview.subject}
                  </p>
                  <p className="mt-1 text-[10px] text-slate-500">
                    {preview.preview.preheader}
                  </p>
                  <p className="mt-3 max-h-52 overflow-y-auto whitespace-pre-wrap text-[11px] leading-5 text-slate-600">
                    {preview.preview.text}
                  </p>
                </div>
              )}
              {preview.eligibleEventCount > 0 ? (
                <button
                  type="button"
                  onClick={() => void confirm()}
                  disabled={Boolean(busy)}
                  className="inline-flex h-10 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-bold text-white hover:bg-brand-900 disabled:opacity-50"
                >
                  {busy === "confirm"
                    ? <Loader2 className="size-4 animate-spin" />
                    : <Send className="size-4" />}
                  {preview.eligibleEventCount.toLocaleString("nl-NL")} event(s)
                  bevestigen
                </button>
              ) : (
                <p className="rounded-lg border border-slate-200 bg-slate-50 p-3 text-[11px] leading-5 text-slate-600">
                  Er zijn geen actuele geschikte ontvangers. Pas de selectie of
                  het proces aan en voer opnieuw een preflight uit.
                </p>
              )}
              <button
                type="button"
                onClick={() => setPreview(null)}
                disabled={Boolean(busy)}
                className="h-9 w-full text-xs font-semibold text-slate-500"
              >
                Selectie wijzigen
              </button>
            </div>
          ) : (
            <div className="mt-5">
              <p className="text-xs leading-6 text-slate-500">
                De database controleert vlak vóór enqueue opnieuw toegang,
                processtatus, betaling, maatstatus en voorraad. De preflight
                toont geen ontvangeradres of geboortedatum.
              </p>
              <button
                type="button"
                onClick={() => void makePreview()}
                disabled={Boolean(busy) || selected.size === 0 || !templateKey}
                className="mt-4 inline-flex h-10 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-bold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:opacity-40"
              >
                {busy === "preview"
                  ? <Loader2 className="size-4 animate-spin" />
                  : <Eye className="size-4" />}
                Preflight uitvoeren
              </button>
            </div>
          )}
          {confirmation && (
            <p className="mt-4 text-[10px] text-slate-400">
              Run {confirmation.runId.slice(0, 8)} veilig vastgelegd.
            </p>
          )}
        </section>

        <section className="overflow-hidden rounded-xl border border-line bg-white shadow-card">
          <div className="border-b border-line px-5 py-4">
            <h2 className="text-sm font-bold text-brand-900">Recente campagneruns</h2>
            <p className="mt-1 text-[11px] text-slate-400">
              Alleen aantallen en procesmetadata
            </p>
          </div>
          {campaignWorkspace.recentRuns.length === 0 ? (
            <Empty
              icon={Users}
              title="Nog geen v2-campagnes"
              text="Bevestigde campagneruns verschijnen hier zonder persoonsgegevens."
            />
          ) : (
            <div className="divide-y divide-line">
              {campaignWorkspace.recentRuns.slice(0, 8).map((run) => (
                <div key={run.runId} className="flex items-center justify-between gap-3 px-5 py-3">
                  <div className="min-w-0">
                    <p className="truncate text-[11px] font-bold text-brand-900">
                      {campaignTemplateLabels[run.templateKey]}
                    </p>
                    <p className="mt-1 text-[10px] text-slate-400">
                      {dateFormatter.format(new Date(run.createdAt))}
                    </p>
                  </div>
                  <span className="shrink-0 rounded-full bg-brand-50 px-2 py-1 text-[10px] font-bold text-brand-700">
                    {run.parentGroupCount} groep(en)
                  </span>
                </div>
              ))}
            </div>
          )}
        </section>
      </aside>
    </div>
  );
}

function CampaignMetric({ label, value }: { label: string; value: number }) {
  return (
    <div className="rounded-lg border border-line bg-slate-50 p-3">
      <p className="text-[9px] font-bold uppercase tracking-[0.08em] text-slate-400">
        {label}
      </p>
      <p className="mt-1 text-lg font-bold text-brand-900">
        {value.toLocaleString("nl-NL")}
      </p>
    </div>
  );
}

function BulkPanel({ workspace, emailEnabled }: { workspace: Workspace; emailEnabled: boolean }) {
  const router = useRouter();
  const [templateKey, setTemplateKey] = useState<BulkEmailTemplateKey>("payment_reminder");
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [preview, setPreview] = useState<(Preview & { token: string; count: number }) | null>(null);
  const [notice, setNotice] = useState<Notice>(null);
  const [busy, setBusy] = useState(false);
  const eligible = useMemo(() => workspace.orders.filter((order) => templateKey === "payment_reminder" ? order.paymentReminderEligible : order.readyForPickupEligible), [workspace.orders, templateKey]);
  const visible = eligible.filter((order) => `${order.memberName} ${order.relationNumber ?? ""} ${order.team}`.toLowerCase().includes(query.trim().toLowerCase()));
  useEffect(() => { setSelected(new Set()); setPreview(null); setNotice(null); }, [templateKey]);
  function toggle(orderId: string) { setPreview(null); setSelected((current) => { const next = new Set(current); if (next.has(orderId)) next.delete(orderId); else next.add(orderId); return next; }); }

  async function makePreview() {
    setBusy(true); setNotice(null);
    try {
      const response = await postJson("/api/email/bulk", { action: "preview", templateKey, orderIds: [...selected] });
      setPreview({ token: String(response.previewToken), count: Number(response.recipientCount), ...(response.preview as Preview) });
    } catch (error) { setNotice({ tone: "error", text: error instanceof Error ? error.message : "Voorvertoning mislukt." }); }
    finally { setBusy(false); }
  }

  async function confirm() {
    if (!preview) return;
    setBusy(true); setNotice(null);
    try {
      const response = await postJson("/api/email/bulk", { action: "confirm", previewToken: preview.token });
      setNotice({ tone: "success", text: `${Number(response.jobCount).toLocaleString("nl-NL")} afzonderlijke e-mailjobs zijn veilig klaargezet.` });
      setSelected(new Set()); setPreview(null); router.refresh();
    } catch (error) { setNotice({ tone: "error", text: error instanceof Error ? error.message : "Bevestigen mislukt." }); }
    finally { setBusy(false); }
  }

  return <div className="grid items-start gap-6 xl:grid-cols-[minmax(0,1fr)_380px]">
    <section className="overflow-hidden rounded-xl border border-line bg-white shadow-card">
      <div className="border-b border-line p-6"><div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between"><div><p className="text-[10px] font-bold uppercase tracking-[0.12em] text-brand-500">Handmatige bulkactie</p><h2 className="mt-1 text-lg font-bold text-brand-900">Bestellingen selecteren</h2><p className="mt-1 text-xs text-slate-500">Elk geselecteerd lid krijgt één afzonderlijk bericht. De database controleert de selectie opnieuw bij bevestiging.</p></div><label className="text-xs font-semibold text-ink">Berichttype<select value={templateKey} onChange={(event) => setTemplateKey(event.target.value as BulkEmailTemplateKey)} className={`${fieldClass} h-10 min-w-56`}><option value="payment_reminder">Betalingsherinnering</option><option value="ready_for_pickup">Artikelen af te halen</option></select></label></div><div className="relative mt-5"><Search className="absolute left-3 top-3 size-4 text-slate-400" /><input value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Zoek op naam, relatienummer of team" className="h-10 w-full rounded-lg border border-line pl-9 pr-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></div></div>
      {visible.length === 0 ? <Empty icon={Users} title="Geen geschikte bestellingen" text={query ? "Geen resultaat binnen de actuele filters." : "Er zijn momenteel geen bestellingen die aan deze servercriteria voldoen."} /> : <><div className="flex items-center justify-between border-b border-line bg-slate-50/60 px-6 py-3"><label className="flex items-center gap-2 text-[11px] font-bold text-slate-600"><input type="checkbox" checked={visible.every((order) => selected.has(order.orderId))} onChange={(event) => { setPreview(null); setSelected((current) => { const next = new Set(current); visible.forEach((order) => event.target.checked ? next.add(order.orderId) : next.delete(order.orderId)); return next; }); }} className="size-4 accent-brand-700" /> Selecteer zichtbare ({visible.length})</label><span className="text-[11px] font-bold text-brand-700">{selected.size} geselecteerd</span></div><div className="max-h-[560px] divide-y divide-line overflow-y-auto">{visible.map((order) => <label key={order.orderId} className="flex cursor-pointer items-center gap-4 px-6 py-4 hover:bg-slate-50"><input type="checkbox" checked={selected.has(order.orderId)} onChange={() => toggle(order.orderId)} className="size-4 shrink-0 accent-brand-700" /><span className="min-w-0 flex-1"><span className="block truncate text-xs font-bold text-brand-900">{order.memberName}</span><span className="mt-1 block text-[10px] text-slate-400">{order.relationNumber ?? "Geen relatienummer"} · {order.team} · {order.season}</span></span><span className="text-right text-[10px] font-semibold text-slate-500">{templateKey === "payment_reminder" ? new Intl.NumberFormat("nl-NL", { style: "currency", currency: "EUR" }).format(order.amountDueCents / 100) : `${order.lines.filter((line) => line.status === "ready_for_pickup").length} gereed`}</span></label>)}</div></>}
    </section>
    <aside className="space-y-6">
      <StatusNotice notice={notice} />
      <section className="rounded-xl border border-line bg-white p-6 shadow-card"><div className="flex items-center gap-3"><span className="flex size-10 items-center justify-center rounded-xl bg-brand-50 text-brand-700"><ShieldCheck className="size-5" /></span><div><h2 className="text-sm font-bold text-brand-900">Controle en bevestiging</h2><p className="mt-1 text-[11px] text-slate-400">Previewtoken tien minuten geldig</p></div></div>{!emailEnabled && <div className="mt-4 rounded-lg border border-amber-200 bg-amber-50 p-3 text-[11px] leading-5 text-amber-800">Jobs kunnen worden voorbereid, maar verzending staat gepauzeerd via de safety switch.</div>}{preview ? <div className="mt-5"><div className="rounded-lg border border-brand-100 bg-brand-50 p-4"><p className="text-[10px] font-bold uppercase tracking-[0.1em] text-brand-500">Fictief voorbeeld · {preview.count} ontvangers</p><p className="mt-2 text-xs font-bold text-brand-900">{preview.subject}</p><p className="mt-2 whitespace-pre-wrap text-[11px] leading-5 text-slate-600">{preview.text}</p></div><button type="button" onClick={() => void confirm()} disabled={busy} className="mt-4 inline-flex h-10 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-bold text-white hover:bg-brand-900 disabled:opacity-50">{busy ? <Loader2 className="size-4 animate-spin" /> : <Send className="size-4" />} {preview.count} jobs bevestigen</button><button type="button" onClick={() => setPreview(null)} disabled={busy} className="mt-2 h-9 w-full text-xs font-semibold text-slate-500">Selectie wijzigen</button></div> : <div className="mt-5"><p className="text-xs leading-6 text-slate-500">Controleer eerst het exacte aantal en een fictief bericht. Betaalstatus en artikelstatus worden bij bevestiging nogmaals server-side gecontroleerd.</p><button type="button" onClick={() => void makePreview()} disabled={busy || selected.size === 0} className="mt-4 inline-flex h-10 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-bold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:opacity-40">{busy ? <Loader2 className="size-4 animate-spin" /> : <Eye className="size-4" />} Voorbeeld en aantal</button></div>}</section>
    </aside>
  </div>;
}

function DeliveryPanel({ workspace }: { workspace: Workspace }) {
  const statusLabels: Record<string, string> = { queued: "In wachtrij", processing: "Bezig", retry: "Nieuwe poging", sent: "Verzonden", failed: "Mislukt", delivery_uncertain: "Aflevering onzeker", superseded: "Vervangen", delivered: "Afgeleverd", bounced: "Bounce", deferred: "Uitgesteld", dropped: "Geweigerd" };
  return <div className="space-y-6">
    <section className="overflow-hidden rounded-xl border border-line bg-white shadow-card"><div className="flex items-center justify-between border-b border-line px-6 py-5"><div><h2 className="text-base font-bold text-brand-900">Recente e-mailjobs</h2><p className="mt-1 text-xs text-slate-500">Maximaal vijf pogingen; gevoelige ontvangergegevens worden hier niet getoond.</p></div><RefreshCw className="size-4 text-slate-400" /></div>{workspace.jobs.length === 0 ? <Empty icon={Send} title="Nog geen e-mailjobs" text="Transactionele triggers en bevestigde bulkacties verschijnen hier." /> : <div className="overflow-x-auto"><table className="w-full min-w-[980px] text-left"><thead><tr className="border-b border-line bg-slate-50/70 text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400"><th className="px-6 py-3">Template</th><th className="px-3 py-3">Wachtrijstatus</th><th className="px-3 py-3">Afleverstatus</th><th className="px-3 py-3">Pogingen</th><th className="px-3 py-3">Herstel</th><th className="px-6 py-3 text-right">Aangemaakt</th></tr></thead><tbody className="divide-y divide-line">{workspace.jobs.map((job) => <tr key={job.id} className="align-top"><td className="px-6 py-3 text-xs font-bold text-brand-900">{emailJobLabels[job.templateKey] ?? job.templateKey}</td><td className="px-3 py-3"><StatusBadge status={job.status} label={statusLabels[job.status]} /></td><td className="px-3 py-3">{job.deliveryStatus ? <StatusBadge status={job.deliveryStatus} label={statusLabels[job.deliveryStatus]} /> : <span className="text-xs text-slate-300">—</span>}</td><td className="px-3 py-3 text-xs text-slate-600">{job.attempts} / 5</td><td className="max-w-[360px] px-3 py-3">{workspace.recoveryAllowed && job.recoverable ? <RecoveryControls job={job} /> : <span className="text-[11px] text-slate-300">—</span>}</td><td className="px-6 py-3 text-right text-[11px] text-slate-400">{dateFormatter.format(new Date(job.createdAt))}</td></tr>)}</tbody></table></div>}</section>
    <section className="overflow-hidden rounded-xl border border-line bg-white shadow-card"><div className="border-b border-line px-6 py-5"><h2 className="text-base font-bold text-brand-900">Recente bulkacties</h2><p className="mt-1 text-xs text-slate-500">Idempotente batches per template, selectie en bevestigingssleutel.</p></div>{workspace.batches.length === 0 ? <Empty icon={Users} title="Nog geen bulkacties" text="Handmatig bevestigde herinneringen en gereedmeldingen verschijnen hier." /> : <div className="divide-y divide-line">{workspace.batches.map((batch) => <div key={batch.id} className="flex items-center justify-between gap-4 px-6 py-4"><div><p className="text-xs font-bold text-brand-900">{emailTemplateLabels[batch.templateKey]}</p><p className="mt-1 text-[10px] text-slate-400">{dateFormatter.format(new Date(batch.createdAt))}</p></div><span className="rounded-full bg-brand-50 px-2.5 py-1 text-[10px] font-bold text-brand-700">{batch.selectedCount.toLocaleString("nl-NL")} jobs</span></div>)}</div>}</section>
  </div>;
}

function RecoveryControls({ job }: { job: Workspace["jobs"][number] }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [resolution, setResolution] = useState<"confirm_sent" | "retry_proven_not_accepted">("confirm_sent");
  const [providerMessageId, setProviderMessageId] = useState("");
  const [evidenceRef, setEvidenceRef] = useState("");
  const [attested, setAttested] = useState(false);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<Notice>(null);

  async function recover(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    setNotice(null);
    try {
      await postJson(`/api/email/jobs/${job.id}/recovery`, {
        expectedUpdatedAt: job.updatedAt,
        resolution,
        reason: resolution === "confirm_sent" ? "provider_confirmed_accepted" : "provider_confirmed_not_accepted",
        providerEvidenceRef: evidenceRef,
        providerMessageId: resolution === "confirm_sent" ? providerMessageId : null,
        attestedNotAccepted: resolution === "retry_proven_not_accepted" && attested,
      });
      setNotice({ tone: "success", text: resolution === "confirm_sent" ? "Provideracceptatie is vastgelegd zonder herverzending." : "Alleen deze bewezen niet-geaccepteerde job is opnieuw ingepland." });
      router.refresh();
    } catch (error) {
      setNotice({ tone: "error", text: error instanceof Error ? error.message : "Herstel is geweigerd." });
    } finally {
      setBusy(false);
    }
  }

  if (!open) return <button type="button" onClick={() => setOpen(true)} className="h-8 rounded-lg border border-amber-200 bg-amber-50 px-3 text-[11px] font-bold text-amber-800 hover:bg-amber-100">Bewijs beoordelen</button>;
  return <form onSubmit={(event) => void recover(event)} className="space-y-3 rounded-lg border border-amber-200 bg-amber-50 p-3">
    <p className="text-[11px] font-bold text-amber-900">Geen automatische herverzending</p>
    <p className="text-[10px] leading-4 text-amber-800">Controleer eerst bij SendGrid of het bericht aantoonbaar is geaccepteerd of aantoonbaar niet is geaccepteerd.</p>
    <label className="block text-[10px] font-bold text-amber-900">Besluit<select value={resolution} onChange={(event) => { setResolution(event.target.value as typeof resolution); setAttested(false); }} className={`${fieldClass} h-9 text-[11px]`}><option value="confirm_sent">Geaccepteerd — niet opnieuw sturen</option><option value="retry_proven_not_accepted">Niet geaccepteerd — opnieuw inplannen</option></select></label>
    {resolution === "confirm_sent" && <label className="block text-[10px] font-bold text-amber-900">Providerbericht-ID<input value={providerMessageId} onChange={(event) => setProviderMessageId(event.target.value)} required minLength={3} maxLength={240} autoComplete="off" className={`${fieldClass} h-9 text-[11px]`} /></label>}
    <label className="block text-[10px] font-bold text-amber-900">Bewijsreferentie<input value={evidenceRef} onChange={(event) => setEvidenceRef(event.target.value)} required minLength={8} maxLength={120} pattern="[A-Za-z0-9][A-Za-z0-9._:/-]*" autoComplete="off" placeholder="ticket/SG-12345" className={`${fieldClass} h-9 text-[11px]`} /></label>
    {resolution === "retry_proven_not_accepted" && <label className="flex items-start gap-2 text-[10px] leading-4 text-amber-900"><input type="checkbox" checked={attested} onChange={(event) => setAttested(event.target.checked)} required className="mt-0.5 size-4 accent-brand-700" /><span>Ik bevestig dat providerbewijs aantoont dat SendGrid dit bericht niet heeft geaccepteerd.</span></label>}
    <StatusNotice notice={notice} />
    <div className="flex gap-2"><button type="submit" disabled={busy} className="h-8 rounded-lg bg-brand-700 px-3 text-[10px] font-bold text-white disabled:opacity-50">{busy ? "Bezig…" : "Besluit vastleggen"}</button><button type="button" onClick={() => setOpen(false)} disabled={busy} className="h-8 px-2 text-[10px] font-bold text-slate-500">Annuleren</button></div>
  </form>;
}

function StatusBadge({ status, label }: { status: string; label: string }) {
  const danger = ["failed", "bounced", "dropped", "delivery_uncertain"].includes(status);
  const success = ["sent", "delivered"].includes(status);
  return <span className={`inline-flex rounded-full px-2 py-1 text-[10px] font-bold ${danger ? "bg-red-50 text-danger" : success ? "bg-emerald-50 text-success" : "bg-amber-50 text-amber-700"}`}>{label}</span>;
}

function Empty({ icon: Icon, title, text }: { icon: typeof Mail; title: string; text: string }) {
  return <div className="px-6 py-14 text-center"><Icon className="mx-auto size-8 text-slate-300" /><p className="mt-4 text-sm font-bold text-slate-600">{title}</p><p className="mx-auto mt-1 max-w-md text-xs leading-5 text-slate-400">{text}</p></div>;
}
