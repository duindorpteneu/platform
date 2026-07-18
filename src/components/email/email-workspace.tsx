"use client";

import { AlertTriangle, Check, CheckCircle2, Clock3, Eye, FileText, Loader2, Mail, RefreshCw, Search, Send, ShieldCheck, Users } from "lucide-react";
import { FormEvent, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { emailTemplateLabels, type BulkEmailTemplateKey, type EmailWorkspace as Workspace } from "@/lib/email-contract";

type Tab = "templates" | "bulk" | "delivery";
type Notice = { tone: "success" | "error"; text: string } | null;
type Preview = { subject: string; text: string };

const fieldClass = "mt-2 w-full rounded-lg border border-line bg-white px-3 text-sm text-ink outline-none transition focus:border-brand-500 focus:ring-2 focus:ring-brand-100 disabled:bg-slate-50 disabled:text-slate-400";
const dateFormatter = new Intl.DateTimeFormat("nl-NL", { dateStyle: "short", timeStyle: "short" });

async function postJson(path: string, body: unknown) {
  const response = await fetch(path, { method: "POST", headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" }, body: JSON.stringify(body) });
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

export function EmailWorkspace({ workspace, emailEnabled }: { workspace: Workspace; emailEnabled: boolean }) {
  const [tab, setTab] = useState<Tab>("templates");
  const failed = workspace.jobs.filter((job) => job.status === "failed" || ["bounced", "dropped", "failed"].includes(job.deliveryStatus ?? "")).length;
  const queued = workspace.jobs.filter((job) => ["queued", "processing", "retry"].includes(job.status)).length;
  const delivered = workspace.jobs.filter((job) => job.deliveryStatus === "delivered").length;

  return <div className="mx-auto max-w-[1400px]">
    <header className="flex flex-col gap-5 lg:flex-row lg:items-end lg:justify-between">
      <div><p className="text-xs font-semibold uppercase tracking-[0.12em] text-brand-500">Transactionele communicatie</p><h1 className="mt-2 text-[30px] font-bold tracking-[-0.04em] text-brand-900 md:text-[34px]">E-mailcentrum</h1><p className="mt-2 max-w-2xl text-sm leading-6 text-slate-500">Beheer veilige clubtemplates, stel handmatige bulkacties samen en volg de duurzame verzendwachtrij.</p></div>
      <div className={`inline-flex h-10 items-center gap-2 self-start rounded-lg border px-3 text-xs font-bold ${emailEnabled ? "border-emerald-200 bg-emerald-50 text-success" : "border-amber-200 bg-amber-50 text-amber-800"}`}><span className={`size-2 rounded-full ${emailEnabled ? "bg-emerald-500" : "bg-amber-500"}`} />{emailEnabled ? "Verzending actief" : "Verzending gepauzeerd"}</div>
    </header>

    <section className="mt-6 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
      <Metric icon={FileText} label="Actieve templates" value={String(workspace.templates.filter((template) => template.active).length)} detail="Canonieke berichttypen" />
      <Metric icon={Clock3} label="In wachtrij" value={String(queued)} detail="Inclusief veilige retries" />
      <Metric icon={CheckCircle2} label="Afgeleverd" value={String(delivered)} detail="Recente operationele jobs" />
      <Metric icon={AlertTriangle} label="Aandacht nodig" value={String(failed)} detail="Failed, bounce of drop" tone={failed ? "danger" : "normal"} />
    </section>

    <nav className="mt-6 flex gap-1 overflow-x-auto rounded-xl border border-line bg-white p-1 shadow-card" aria-label="E-mailonderdelen">
      {([{ id: "templates", label: "Templates", icon: FileText }, { id: "bulk", label: "Bulkmail", icon: Users }, { id: "delivery", label: "Verzending", icon: Send }] as const).map((entry) => <button key={entry.id} type="button" onClick={() => setTab(entry.id)} className={`inline-flex h-10 min-w-fit flex-1 items-center justify-center gap-2 rounded-lg px-4 text-xs font-bold transition ${tab === entry.id ? "bg-brand-700 text-white" : "text-slate-500 hover:bg-slate-50 hover:text-brand-900"}`}><entry.icon className="size-4" />{entry.label}</button>)}
    </nav>

    <div className="mt-6">
      {tab === "templates" && <TemplatesPanel workspace={workspace} />}
      {tab === "bulk" && <BulkPanel workspace={workspace} emailEnabled={emailEnabled} />}
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
  if (!template) return <Empty icon={FileText} title="Geen templates beschikbaar" text="De zes canonieke templates zijn nog niet veilig geladen." />;

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
    <aside className="overflow-hidden rounded-xl border border-line bg-white shadow-card"><div className="border-b border-line px-5 py-4"><h2 className="text-sm font-bold text-brand-900">Berichttypen</h2><p className="mt-1 text-[11px] text-slate-400">Exact zes canonieke templates</p></div><div className="divide-y divide-line">{workspace.templates.map((entry) => <button key={entry.id} type="button" onClick={() => setSelectedId(entry.id)} className={`flex w-full items-center gap-3 px-4 py-4 text-left transition ${entry.id === template.id ? "bg-brand-50" : "hover:bg-slate-50"}`}><span className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-white text-brand-700 shadow-sm"><Mail className="size-4" /></span><span className="min-w-0 flex-1"><span className="block truncate text-xs font-bold text-brand-900">{emailTemplateLabels[entry.key]}</span><span className="mt-1 block text-[10px] text-slate-400">Versie {entry.version} · {entry.active ? "Actief" : "Inactief"}</span></span></button>)}</div></aside>
    <div>
      <StatusNotice notice={notice} />
      <form onSubmit={save} className="rounded-xl border border-line bg-white p-6 shadow-card">
        <div className="flex flex-col gap-3 border-b border-line pb-5 sm:flex-row sm:items-start sm:justify-between"><div><p className="text-[10px] font-bold uppercase tracking-[0.12em] text-brand-500">Template bewerken</p><h2 className="mt-1 text-lg font-bold text-brand-900">{emailTemplateLabels[template.key]}</h2><p className="mt-1 text-xs text-slate-500">Alleen platte tekst en toegestane shortcodes; HTML en scripts worden geweigerd.</p></div><span className="rounded-full bg-slate-100 px-2.5 py-1 text-[10px] font-bold text-slate-500">v{template.version}</span></div>
        {template.key === "verification_code" && <div className="mt-5 flex gap-3 rounded-xl border border-brand-100 bg-brand-50 p-4 text-xs leading-5 text-brand-900"><ShieldCheck className="mt-0.5 size-4 shrink-0 text-brand-700" /><p>De zescijferige code wordt als vast beveiligd blok door de OTP-provider toegevoegd. De code wordt niet duurzaam in de template of jobqueue opgeslagen.</p></div>}
        <fieldset disabled={Boolean(busy) || template.key === "verification_code"} className="mt-5 space-y-4"><label className="block text-xs font-semibold text-ink">Onderwerp<input className={`${fieldClass} h-11`} value={subject} onChange={(event) => setSubject(event.target.value)} maxLength={180} required /></label><label className="block text-xs font-semibold text-ink">Berichttekst<textarea className={`${fieldClass} min-h-52 py-3 leading-6`} value={body} onChange={(event) => setBody(event.target.value)} maxLength={10_000} required /></label></fieldset>
        {template.key !== "verification_code" && <div className="mt-5"><p className="text-[10px] font-bold uppercase tracking-[0.1em] text-slate-400">Toegestane shortcodes</p><div className="mt-2 flex flex-wrap gap-2">{template.allowedShortcodes.map((code) => <button key={code} type="button" onClick={() => setBody((value) => `${value}${value.endsWith(" ") || !value ? "" : " "}${code}`)} className="rounded-md border border-line bg-slate-50 px-2 py-1 font-mono text-[10px] text-brand-700 hover:border-brand-300">{code}</button>)}</div></div>}
        <div className="mt-6 flex flex-col-reverse gap-2 border-t border-line pt-5 sm:flex-row sm:justify-end"><button type="button" onClick={() => void previewTemplate()} disabled={Boolean(busy)} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-line px-4 text-xs font-bold text-brand-700 hover:border-brand-300 disabled:opacity-50">{busy === "preview" ? <Loader2 className="size-4 animate-spin" /> : <Eye className="size-4" />} Fictief voorbeeld</button>{template.key !== "verification_code" && <button type="submit" disabled={Boolean(busy)} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-bold text-white hover:bg-brand-900 disabled:opacity-50">{busy === "save" ? <Loader2 className="size-4 animate-spin" /> : <Check className="size-4" />} Template opslaan</button>}</div>
      </form>
      {preview && <section className="mt-6 rounded-xl border border-line bg-white p-6 shadow-card"><div className="flex items-center justify-between"><div><p className="text-[10px] font-bold uppercase tracking-[0.1em] text-brand-500">Fictieve voorvertoning</p><h3 className="mt-1 text-sm font-bold text-brand-900">Geen echte ledengegevens gebruikt</h3></div><Eye className="size-5 text-brand-500" /></div><div className="mt-4 rounded-lg border border-line bg-slate-50 p-4"><p className="text-xs font-bold text-brand-900">{preview.subject}</p><p className="mt-3 whitespace-pre-wrap text-xs leading-6 text-slate-600">{preview.text}</p></div></section>}
    </div>
  </div>;
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
  const visible = eligible.filter((order) => `${order.memberName} ${order.relationNumber} ${order.team}`.toLowerCase().includes(query.trim().toLowerCase()));
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
      {visible.length === 0 ? <Empty icon={Users} title="Geen geschikte bestellingen" text={query ? "Geen resultaat binnen de actuele filters." : "Er zijn momenteel geen bestellingen die aan deze servercriteria voldoen."} /> : <><div className="flex items-center justify-between border-b border-line bg-slate-50/60 px-6 py-3"><label className="flex items-center gap-2 text-[11px] font-bold text-slate-600"><input type="checkbox" checked={visible.every((order) => selected.has(order.orderId))} onChange={(event) => { setPreview(null); setSelected((current) => { const next = new Set(current); visible.forEach((order) => event.target.checked ? next.add(order.orderId) : next.delete(order.orderId)); return next; }); }} className="size-4 accent-brand-700" /> Selecteer zichtbare ({visible.length})</label><span className="text-[11px] font-bold text-brand-700">{selected.size} geselecteerd</span></div><div className="max-h-[560px] divide-y divide-line overflow-y-auto">{visible.map((order) => <label key={order.orderId} className="flex cursor-pointer items-center gap-4 px-6 py-4 hover:bg-slate-50"><input type="checkbox" checked={selected.has(order.orderId)} onChange={() => toggle(order.orderId)} className="size-4 shrink-0 accent-brand-700" /><span className="min-w-0 flex-1"><span className="block truncate text-xs font-bold text-brand-900">{order.memberName}</span><span className="mt-1 block text-[10px] text-slate-400">{order.relationNumber} · {order.team} · {order.season}</span></span><span className="text-right text-[10px] font-semibold text-slate-500">{templateKey === "payment_reminder" ? new Intl.NumberFormat("nl-NL", { style: "currency", currency: "EUR" }).format(order.amountDueCents / 100) : `${order.lines.filter((line) => line.status === "ready_for_pickup").length} gereed`}</span></label>)}</div></>}
    </section>
    <aside className="space-y-6">
      <StatusNotice notice={notice} />
      <section className="rounded-xl border border-line bg-white p-6 shadow-card"><div className="flex items-center gap-3"><span className="flex size-10 items-center justify-center rounded-xl bg-brand-50 text-brand-700"><ShieldCheck className="size-5" /></span><div><h2 className="text-sm font-bold text-brand-900">Controle en bevestiging</h2><p className="mt-1 text-[11px] text-slate-400">Previewtoken tien minuten geldig</p></div></div>{!emailEnabled && <div className="mt-4 rounded-lg border border-amber-200 bg-amber-50 p-3 text-[11px] leading-5 text-amber-800">Jobs kunnen worden voorbereid, maar verzending staat gepauzeerd via de safety switch.</div>}{preview ? <div className="mt-5"><div className="rounded-lg border border-brand-100 bg-brand-50 p-4"><p className="text-[10px] font-bold uppercase tracking-[0.1em] text-brand-500">Fictief voorbeeld · {preview.count} ontvangers</p><p className="mt-2 text-xs font-bold text-brand-900">{preview.subject}</p><p className="mt-2 whitespace-pre-wrap text-[11px] leading-5 text-slate-600">{preview.text}</p></div><button type="button" onClick={() => void confirm()} disabled={busy} className="mt-4 inline-flex h-10 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-bold text-white hover:bg-brand-900 disabled:opacity-50">{busy ? <Loader2 className="size-4 animate-spin" /> : <Send className="size-4" />} {preview.count} jobs bevestigen</button><button type="button" onClick={() => setPreview(null)} disabled={busy} className="mt-2 h-9 w-full text-xs font-semibold text-slate-500">Selectie wijzigen</button></div> : <div className="mt-5"><p className="text-xs leading-6 text-slate-500">Controleer eerst het exacte aantal en een fictief bericht. Betaalstatus en artikelstatus worden bij bevestiging nogmaals server-side gecontroleerd.</p><button type="button" onClick={() => void makePreview()} disabled={busy || selected.size === 0} className="mt-4 inline-flex h-10 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-bold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:opacity-40">{busy ? <Loader2 className="size-4 animate-spin" /> : <Eye className="size-4" />} Voorbeeld en aantal</button></div>}</section>
    </aside>
  </div>;
}

function DeliveryPanel({ workspace }: { workspace: Workspace }) {
  const statusLabels: Record<string, string> = { queued: "In wachtrij", processing: "Bezig", retry: "Nieuwe poging", sent: "Verzonden", failed: "Mislukt", delivered: "Afgeleverd", bounced: "Bounce", deferred: "Uitgesteld", dropped: "Geweigerd" };
  return <div className="space-y-6">
    <section className="overflow-hidden rounded-xl border border-line bg-white shadow-card"><div className="flex items-center justify-between border-b border-line px-6 py-5"><div><h2 className="text-base font-bold text-brand-900">Recente e-mailjobs</h2><p className="mt-1 text-xs text-slate-500">Maximaal vijf pogingen; gevoelige ontvangergegevens worden hier niet getoond.</p></div><RefreshCw className="size-4 text-slate-400" /></div>{workspace.jobs.length === 0 ? <Empty icon={Send} title="Nog geen e-mailjobs" text="Transactionele triggers en bevestigde bulkacties verschijnen hier." /> : <div className="overflow-x-auto"><table className="w-full min-w-[780px] text-left"><thead><tr className="border-b border-line bg-slate-50/70 text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400"><th className="px-6 py-3">Template</th><th className="px-3 py-3">Wachtrijstatus</th><th className="px-3 py-3">Afleverstatus</th><th className="px-3 py-3">Pogingen</th><th className="px-6 py-3 text-right">Aangemaakt</th></tr></thead><tbody className="divide-y divide-line">{workspace.jobs.map((job) => <tr key={job.id}><td className="px-6 py-3 text-xs font-bold text-brand-900">{emailTemplateLabels[job.templateKey]}</td><td className="px-3 py-3"><StatusBadge status={job.status} label={statusLabels[job.status]} /></td><td className="px-3 py-3">{job.deliveryStatus ? <StatusBadge status={job.deliveryStatus} label={statusLabels[job.deliveryStatus]} /> : <span className="text-xs text-slate-300">—</span>}</td><td className="px-3 py-3 text-xs text-slate-600">{job.attempts} / 5</td><td className="px-6 py-3 text-right text-[11px] text-slate-400">{dateFormatter.format(new Date(job.createdAt))}</td></tr>)}</tbody></table></div>}</section>
    <section className="overflow-hidden rounded-xl border border-line bg-white shadow-card"><div className="border-b border-line px-6 py-5"><h2 className="text-base font-bold text-brand-900">Recente bulkacties</h2><p className="mt-1 text-xs text-slate-500">Idempotente batches per template, selectie en bevestigingssleutel.</p></div>{workspace.batches.length === 0 ? <Empty icon={Users} title="Nog geen bulkacties" text="Handmatig bevestigde herinneringen en gereedmeldingen verschijnen hier." /> : <div className="divide-y divide-line">{workspace.batches.map((batch) => <div key={batch.id} className="flex items-center justify-between gap-4 px-6 py-4"><div><p className="text-xs font-bold text-brand-900">{emailTemplateLabels[batch.templateKey]}</p><p className="mt-1 text-[10px] text-slate-400">{dateFormatter.format(new Date(batch.createdAt))}</p></div><span className="rounded-full bg-brand-50 px-2.5 py-1 text-[10px] font-bold text-brand-700">{batch.selectedCount.toLocaleString("nl-NL")} jobs</span></div>)}</div>}</section>
  </div>;
}

function StatusBadge({ status, label }: { status: string; label: string }) {
  const danger = ["failed", "bounced", "dropped"].includes(status);
  const success = ["sent", "delivered"].includes(status);
  return <span className={`inline-flex rounded-full px-2 py-1 text-[10px] font-bold ${danger ? "bg-red-50 text-danger" : success ? "bg-emerald-50 text-success" : "bg-amber-50 text-amber-700"}`}>{label}</span>;
}

function Empty({ icon: Icon, title, text }: { icon: typeof Mail; title: string; text: string }) {
  return <div className="px-6 py-14 text-center"><Icon className="mx-auto size-8 text-slate-300" /><p className="mt-4 text-sm font-bold text-slate-600">{title}</p><p className="mx-auto mt-1 max-w-md text-xs leading-5 text-slate-400">{text}</p></div>;
}
