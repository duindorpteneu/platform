"use client";

import {
  AlertTriangle,
  CheckCircle2,
  Eye,
  Loader2,
  Mail,
  Monitor,
  Moon,
  Palette,
  Save,
  Send,
  ShieldCheck,
  Smartphone,
  Type,
} from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import type {
  MailBranding,
  MailTemplateKey,
  MailTipTapDocument,
  MailV2CutoverSnapshot,
  MailV2Workspace,
} from "@/lib/mail-v2-contract";
import { MailV2Editor } from "@/components/email/mail-v2-editor";

type Notice = { tone: "success" | "error"; text: string } | null;
type PreviewMode = "desktop" | "mobile" | "dark" | "text";
type Preview = {
  subject: string;
  preheader: string;
  html: string;
  text: string;
};

const templateLabels: Record<MailTemplateKey, string> = {
  portal_access_invite: "Portaaltoegang uitnodiging",
  portal_access_reminder: "Portaaltoegang herinnering",
  login_otp: "Inlogcode",
  size_fill_request: "Maten invullen",
  size_fill_reminder: "Herinnering maten invullen",
  size_review_request: "Maten controleren",
  size_review_reminder: "Herinnering maten controleren",
  size_confirmed: "Maten bevestigd",
  payment_request: "Betaalverzoek",
  payment_reminder: "Betalingsherinnering",
  payment_received_waiting_stock: "Betaling ontvangen, wacht op voorraad",
  available_payment_required: "Voorraad beschikbaar, betaling vereist",
  pickup_ready: "Pakketregels afhaalklaar",
  pickup_reminder: "Afhaalherinnering",
  out_of_stock: "Tijdelijk niet leverbaar",
  back_in_stock: "Weer op voorraad",
  partial_pickup: "Deel van pakket afgehaald",
  package_complete: "Pakket volledig afgehaald",
  internal_email_failure: "Definitieve e-mailfout",
};

const processLabels: Record<MailV2Workspace["templates"][number]["process"], string> = {
  portal_access: "Toegang",
  authentication: "Authenticatie",
  size: "Maten",
  payment: "Betaling",
  inventory: "Voorraad",
  fulfilment: "Uitgifte",
  internal: "Intern",
};

const fieldClass = "mt-2 h-11 w-full rounded-lg border border-line bg-white px-3 text-sm text-ink outline-none transition focus:border-brand-500 focus:ring-2 focus:ring-brand-100 disabled:bg-slate-50 disabled:text-slate-400";

async function postJson(path: string, body: unknown) {
  const response = await fetch(path, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Duindorp-CSRF": "same-origin",
      "X-Correlation-ID": crypto.randomUUID(),
    },
    body: JSON.stringify(body),
  });
  const payload = await response.json() as Record<string, unknown> & { error?: string };
  if (!response.ok) throw new Error(payload.error ?? "De aanvraag kon niet worden verwerkt.");
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

export function MailV2CutoverPanel({
  snapshot,
}: {
  snapshot: MailV2CutoverSnapshot;
}) {
  const router = useRouter();
  const [reason, setReason] = useState("");
  const [confirmed, setConfirmed] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [notice, setNotice] = useState<Notice>(null);
  const complete = snapshot.ready
    && snapshot.catalogCount === 19
    && snapshot.publishedCount === 19
    && snapshot.brandingCount === 1
    && snapshot.producerCount === 19
    && snapshot.legacyPendingCount === 0
    && snapshot.projectionFailureCount === 0
    && snapshot.unresolvedConfirmationCount === 0;

  async function change(action: "activate" | "pause") {
    setBusy(action);
    setNotice(null);
    try {
      await postJson("/api/email/v2/cutover", {
        action,
        ...(action === "activate"
          ? { expectedRevision: snapshot.revision }
          : {}),
        reason,
      });
      setNotice({
        tone: "success",
        text: action === "activate"
          ? "Mail-v2 is geactiveerd met een immutable cutoverwatermerk."
          : "Nieuwe mail-v2-projecties zijn gepauzeerd; het watermerk blijft behouden.",
      });
      setReason("");
      setConfirmed(false);
      router.refresh();
    } catch (error) {
      setNotice({
        tone: "error",
        text: error instanceof Error
          ? error.message
          : "De mailcutover kon niet worden gewijzigd.",
      });
    } finally {
      setBusy(null);
    }
  }

  async function retryProjection(
    failure: MailV2CutoverSnapshot["projectionFailures"][number],
  ) {
    setBusy(`retry:${failure.groupId}`);
    setNotice(null);
    try {
      await postJson("/api/email/v2/projections/retry", {
        groupId: failure.groupId,
        expectedRetryCount: failure.retryCount,
        reason,
      });
      setNotice({
        tone: "success",
        text: "De gecorrigeerde projectie is geauditeerd opnieuw vrijgegeven.",
      });
      setReason("");
      setConfirmed(false);
      router.refresh();
    } catch (error) {
      setNotice({
        tone: "error",
        text: error instanceof Error
          ? error.message
          : "De mailprojectie kon niet veilig opnieuw worden vrijgegeven.",
      });
    } finally {
      setBusy(null);
    }
  }

  return (
    <section className={`mb-6 rounded-xl border p-5 shadow-card ${
      snapshot.enabled
        ? "border-emerald-200 bg-emerald-50"
        : "border-amber-200 bg-amber-50"
    }`}>
      <StatusNotice notice={notice} />
      <div className="flex flex-col gap-5 lg:flex-row lg:items-start lg:justify-between">
        <div className="flex min-w-0 gap-3">
          <span className={`flex size-10 shrink-0 items-center justify-center rounded-xl ${
            snapshot.enabled
              ? "bg-emerald-100 text-success"
              : "bg-amber-100 text-amber-800"
          }`}>
            <ShieldCheck className="size-5" />
          </span>
          <div>
            <p className="text-[10px] font-bold uppercase tracking-[0.12em] text-brand-500">
              Gecontroleerde mailcutover
            </p>
            <h2 className="mt-1 text-sm font-bold text-brand-900">
              {snapshot.enabled ? "Mail-v2-projectie actief" : "Mail-v2-projectie gepauzeerd"}
            </h2>
            <p className="mt-1 max-w-2xl text-[11px] leading-5 text-slate-600">
              Activeren vereist alle 19 gepubliceerde templates, alle 19 bewezen
              producenten, exact één contrastgevalideerde brandingrevisie en een
              lege legacywachtrij zonder projectie- of historiereconciliaties.
              Pauzeren wist het historische cutovermoment niet.
            </p>
            <div className="mt-3 flex flex-wrap gap-2 text-[10px] font-bold">
              <span className="rounded-full bg-white/80 px-2.5 py-1 text-brand-900">
                Catalogus {snapshot.catalogCount} / 19
              </span>
              <span className="rounded-full bg-white/80 px-2.5 py-1 text-brand-900">
                Gepubliceerd {snapshot.publishedCount} / 19
              </span>
              <span className="rounded-full bg-white/80 px-2.5 py-1 text-brand-900">
                Branding {snapshot.brandingCount} / 1
              </span>
              <span className="rounded-full bg-white/80 px-2.5 py-1 text-brand-900">
                Producenten {snapshot.producerCount} / 19
              </span>
              <span className="rounded-full bg-white/80 px-2.5 py-1 text-brand-900">
                Legacywachtrij {snapshot.legacyPendingCount}
              </span>
              <span className="rounded-full bg-white/80 px-2.5 py-1 text-brand-900">
                Projectiefouten {snapshot.projectionFailureCount}
              </span>
              <span className="rounded-full bg-white/80 px-2.5 py-1 text-brand-900">
                Historiereconciliaties {snapshot.unresolvedConfirmationCount}
              </span>
              <span className={`rounded-full px-2.5 py-1 ${
                complete
                  ? "bg-emerald-100 text-success"
                  : "bg-amber-100 text-amber-800"
              }`}>
                {complete ? "Preflight gereed" : "Preflight geblokkeerd"}
              </span>
            </div>
            {snapshot.cutoverAt && (
              <p className="mt-3 text-[10px] text-slate-500">
                Immutable watermerk:{" "}
                {new Intl.DateTimeFormat("nl-NL", {
                  dateStyle: "short",
                  timeStyle: "short",
                }).format(new Date(snapshot.cutoverAt))}
              </p>
            )}
          </div>
        </div>
        <fieldset
          disabled={Boolean(busy)}
          className="w-full shrink-0 space-y-3 rounded-lg border border-white/80 bg-white/70 p-4 lg:w-[360px]"
        >
          <label className="block text-[11px] font-bold text-brand-900">
            Reden
            <textarea
              value={reason}
              onChange={(event) => setReason(event.target.value)}
              minLength={4}
              maxLength={500}
              required
              className={`${fieldClass} h-20 py-2 text-xs`}
              placeholder="Beschrijf de uitgevoerde controle of incidentreden."
            />
          </label>
          <label className="flex items-start gap-2 text-[10px] leading-4 text-slate-600">
            <input
              type="checkbox"
              checked={confirmed}
              onChange={(event) => setConfirmed(event.target.checked)}
              className="mt-0.5 size-4 accent-brand-700"
            />
            <span>
              Ik bevestig dat deze wijziging operationele mailprojectie beïnvloedt
              en door de auditlog wordt vastgelegd.
            </span>
          </label>
          {snapshot.enabled ? (
            <button
              type="button"
              onClick={() => void change("pause")}
              disabled={!confirmed || reason.trim().length < 4}
              className="inline-flex h-10 w-full items-center justify-center gap-2 rounded-lg border border-amber-300 bg-white px-4 text-xs font-bold text-amber-900 disabled:opacity-40"
            >
              {busy === "pause" && <Loader2 className="size-4 animate-spin" />}
              Projectie pauzeren
            </button>
          ) : (
            <button
              type="button"
              onClick={() => void change("activate")}
              disabled={!complete || !confirmed || reason.trim().length < 4}
              className="inline-flex h-10 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-bold text-white disabled:opacity-40"
            >
              {busy === "activate" && <Loader2 className="size-4 animate-spin" />}
              Mail-v2 activeren
            </button>
          )}
        </fieldset>
      </div>
      {snapshot.projectionFailures.length > 0 && (
        <div className="mt-4 rounded-lg border border-red-200 bg-white/80 p-4">
          <h3 className="text-xs font-bold text-brand-900">
            Herstelbare projectiefouten
          </h3>
          <p className="mt-1 text-[10px] leading-4 text-slate-600">
            Controleer eerst de template of renderer. De reden en iedere retry
            worden geaudit; dezelfde immutable domeinevents blijven gebonden.
          </p>
          <div className="mt-3 space-y-2">
            {snapshot.projectionFailures.map((failure) => (
              <div
                key={failure.groupId}
                className="flex flex-col gap-2 rounded-lg border border-line bg-white p-3 sm:flex-row sm:items-center sm:justify-between"
              >
                <div className="text-[10px] text-slate-600">
                  <p className="font-bold text-brand-900">
                    {templateLabels[failure.templateKey]}
                  </p>
                  <p>
                    {failure.eventCount} event(s) · poging {failure.retryCount}/10
                    {" · "}
                    {failure.suppressionReason}
                  </p>
                </div>
                <button
                  type="button"
                  onClick={() => void retryProjection(failure)}
                  disabled={failure.retryCount >= 10
                    || failure.suppressionReason === "retry_exhausted"
                    || !confirmed
                    || reason.trim().length < 4}
                  className="inline-flex h-9 items-center justify-center gap-2 rounded-lg border border-red-200 px-3 text-[10px] font-bold text-danger disabled:opacity-40"
                >
                  {busy === `retry:${failure.groupId}`
                    && <Loader2 className="size-3.5 animate-spin" />}
                  {failure.retryCount >= 10
                    || failure.suppressionReason === "retry_exhausted"
                    ? "Handmatige interventie vereist"
                    : "Opnieuw projecteren"}
                </button>
              </div>
            ))}
          </div>
        </div>
      )}
    </section>
  );
}

export function MailV2TemplatesPanel({ workspace }: { workspace: MailV2Workspace }) {
  const router = useRouter();
  const [selectedKey, setSelectedKey] = useState<MailTemplateKey>(
    workspace.templates[0]?.key ?? "portal_access_invite",
  );
  const template = useMemo(
    () => workspace.templates.find((candidate) => candidate.key === selectedKey) ?? workspace.templates[0],
    [selectedKey, workspace.templates],
  );
  const activeRevision = template?.draft ?? template?.published;
  const [internalName, setInternalName] = useState(activeRevision?.internalName ?? "");
  const [subjectSource, setSubjectSource] = useState(activeRevision?.subjectSource ?? "");
  const [preheaderSource, setPreheaderSource] = useState(activeRevision?.preheaderSource ?? "");
  const [bodyTipTap, setBodyTipTap] = useState<MailTipTapDocument>(
    activeRevision?.bodyTipTap ?? {
      type: "doc",
      content: [{ type: "paragraph", content: [] }],
    },
  );
  const [dirty, setDirty] = useState(false);
  const [busy, setBusy] = useState<"save" | "publish" | "preview" | null>(null);
  const [notice, setNotice] = useState<Notice>(null);
  const [preview, setPreview] = useState<Preview | null>(null);
  const [previewMode, setPreviewMode] = useState<PreviewMode>("desktop");

  useEffect(() => {
    const revision = template?.draft ?? template?.published;
    if (!revision) return;
    setInternalName(revision.internalName);
    setSubjectSource(revision.subjectSource);
    setPreheaderSource(revision.preheaderSource);
    setBodyTipTap(revision.bodyTipTap);
    setDirty(false);
    setNotice(null);
    setPreview(null);
  }, [template]);

  if (!template || !activeRevision) {
    return (
      <div className="rounded-xl border border-line bg-white px-6 py-14 text-center shadow-card">
        <Mail className="mx-auto size-8 text-slate-300" />
        <p className="mt-4 text-sm font-bold text-slate-600">Geen mailtemplates geladen</p>
      </div>
    );
  }

  function markDirty() {
    setDirty(true);
    setPreview(null);
    setNotice(null);
  }

  async function saveDraft() {
    setBusy("save");
    setNotice(null);
    try {
      await postJson("/api/email/v2/templates", {
        action: "save",
        templateKey: template.key,
        expectedHash: template.draft?.contentHash ?? null,
        internalName,
        subjectSource,
        preheaderSource,
        bodyTipTap,
      });
      setNotice({ tone: "success", text: "Concept veilig opgeslagen, gesanitiseerd en geaudit." });
      setDirty(false);
      router.refresh();
    } catch (error) {
      setNotice({ tone: "error", text: error instanceof Error ? error.message : "Opslaan mislukt." });
    } finally {
      setBusy(null);
    }
  }

  async function publishDraft() {
    if (!template.draft || dirty) return;
    setBusy("publish");
    setNotice(null);
    try {
      await postJson("/api/email/v2/templates", {
        action: "publish",
        revisionId: template.draft.id,
        expectedHash: template.draft.contentHash,
      });
      setNotice({ tone: "success", text: "Template gepubliceerd; de vorige gepubliceerde revisie is gearchiveerd." });
      router.refresh();
    } catch (error) {
      setNotice({ tone: "error", text: error instanceof Error ? error.message : "Publiceren mislukt." });
    } finally {
      setBusy(null);
    }
  }

  async function makePreview() {
    setBusy("preview");
    setNotice(null);
    try {
      const payload = await postJson("/api/email/v2/templates/preview", {
        templateKey: template.key,
        internalName,
        subjectSource,
        preheaderSource,
        bodyTipTap,
      });
      setPreview({
        subject: String(payload.subject),
        preheader: String(payload.preheader),
        html: String(payload.html),
        text: String(payload.text),
      });
    } catch (error) {
      setNotice({ tone: "error", text: error instanceof Error ? error.message : "Preview mislukt." });
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="grid items-start gap-6 xl:grid-cols-[330px_minmax(0,1fr)]">
      <aside className="overflow-hidden rounded-xl border border-line bg-white shadow-card">
        <div className="border-b border-line px-5 py-4">
          <h2 className="text-sm font-bold text-brand-900">Mailcatalogus</h2>
          <p className="mt-1 text-[11px] text-slate-400">19 vaste processen · versieerbaar</p>
        </div>
        <div className="max-h-[760px] divide-y divide-line overflow-y-auto">
          {workspace.templates.map((entry) => (
            <button
              key={entry.key}
              type="button"
              onClick={() => setSelectedKey(entry.key)}
              className={`flex w-full items-center gap-3 px-4 py-3.5 text-left transition ${
                entry.key === template.key ? "bg-brand-50" : "hover:bg-slate-50"
              }`}
            >
              <span className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-white text-brand-700 shadow-sm">
                <Mail className="size-4" />
              </span>
              <span className="min-w-0 flex-1">
                <span className="block truncate text-xs font-bold text-brand-900">{templateLabels[entry.key]}</span>
                <span className="mt-1 flex items-center gap-1.5 text-[10px] text-slate-400">
                  {processLabels[entry.process]}
                  <span aria-hidden>·</span>
                  {entry.published ? `Live v${entry.published.revision}` : "Niet gepubliceerd"}
                </span>
              </span>
              {entry.draft && <span className="size-2 rounded-full bg-amber-400" title="Concept aanwezig" />}
            </button>
          ))}
        </div>
      </aside>

      <div>
        <StatusNotice notice={notice} />
        <section className="rounded-xl border border-line bg-white p-6 shadow-card">
          <div className="flex flex-col gap-4 border-b border-line pb-5 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <p className="text-[10px] font-bold uppercase tracking-[0.12em] text-brand-500">
                {processLabels[template.process]} · {template.audience === "external" ? "Extern" : "Intern"}
              </p>
              <h2 className="mt-1 text-lg font-bold text-brand-900">{templateLabels[template.key]}</h2>
              <p className="mt-1 text-xs text-slate-500">
                TipTap-JSON wordt server-side gevalideerd; editor-HTML wordt nooit vertrouwd of opgeslagen.
              </p>
            </div>
            <div className="flex flex-wrap gap-2">
              <span className={`rounded-full px-2.5 py-1 text-[10px] font-bold ${
                template.published ? "bg-emerald-50 text-success" : "bg-slate-100 text-slate-500"
              }`}>
                {template.published ? `Gepubliceerd v${template.published.revision}` : "Niet gepubliceerd"}
              </span>
              {template.draft && (
                <span className="rounded-full bg-amber-50 px-2.5 py-1 text-[10px] font-bold text-amber-700">
                  Concept v{template.draft.revision}
                </span>
              )}
            </div>
          </div>

          <fieldset disabled={Boolean(busy)} className="mt-5 space-y-4">
            <label className="block text-xs font-semibold text-ink">
              Interne naam
              <input
                value={internalName}
                onChange={(event) => { setInternalName(event.target.value); markDirty(); }}
                maxLength={120}
                required
                className={fieldClass}
              />
            </label>
            <label className="block text-xs font-semibold text-ink">
              Onderwerp
              <input
                value={subjectSource}
                onChange={(event) => { setSubjectSource(event.target.value); markDirty(); }}
                maxLength={180}
                required
                className={fieldClass}
              />
            </label>
            <label className="block text-xs font-semibold text-ink">
              Preheader
              <input
                value={preheaderSource}
                onChange={(event) => { setPreheaderSource(event.target.value); markDirty(); }}
                maxLength={240}
                required
                className={fieldClass}
              />
            </label>
            <div>
              <div className="mb-2 flex items-end justify-between gap-4">
                <div>
                  <p className="text-xs font-semibold text-ink">Berichtinhoud</p>
                  <p className="mt-1 text-[10px] text-slate-400">Scripts, HTML, afbeeldingen en vrije CSS zijn niet beschikbaar.</p>
                </div>
                <span className="text-[10px] font-semibold text-slate-400">Schema v1</span>
              </div>
              <MailV2Editor
                revisionKey={`${template.key}:${activeRevision.contentHash}`}
                content={bodyTipTap}
                allowedShortcodes={template.allowedShortcodes}
                protectedNodes={template.allowedProtectedNodes}
                disabled={Boolean(busy)}
                onChange={(document) => {
                  setBodyTipTap(document);
                  markDirty();
                }}
              />
            </div>
          </fieldset>

          <div className="mt-5 grid gap-3 rounded-lg border border-brand-100 bg-brand-50 p-4 lg:grid-cols-2">
            <div>
              <p className="text-[10px] font-bold uppercase tracking-[0.08em] text-brand-500">Verplichte blokken</p>
              <p className="mt-2 text-xs leading-5 text-brand-900">{template.requiredProtectedNodes.join(", ")}</p>
            </div>
            <div>
              <p className="text-[10px] font-bold uppercase tracking-[0.08em] text-brand-500">Getypeerde shortcodes</p>
              <p className="mt-2 text-xs leading-5 text-brand-900">{template.allowedShortcodes.join(", ")}</p>
            </div>
          </div>

          <div className="mt-6 flex flex-col-reverse gap-2 border-t border-line pt-5 sm:flex-row sm:justify-end">
            <button
              type="button"
              onClick={() => void makePreview()}
              disabled={Boolean(busy)}
              className="inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-line px-4 text-xs font-bold text-brand-700 hover:border-brand-300 disabled:opacity-50"
            >
              {busy === "preview" ? <Loader2 className="size-4 animate-spin" /> : <Eye className="size-4" />}
              Preview
            </button>
            <button
              type="button"
              onClick={() => void saveDraft()}
              disabled={Boolean(busy) || !dirty}
              className="inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-brand-200 bg-white px-4 text-xs font-bold text-brand-700 hover:bg-brand-50 disabled:opacity-40"
            >
              {busy === "save" ? <Loader2 className="size-4 animate-spin" /> : <Save className="size-4" />}
              Concept opslaan
            </button>
            <button
              type="button"
              onClick={() => void publishDraft()}
              disabled={Boolean(busy) || dirty || !template.draft || !template.draft.sanitizedHtmlSource}
              title={dirty ? "Sla wijzigingen eerst op" : !template.draft?.sanitizedHtmlSource ? "Sla het concept eerst veilig op" : undefined}
              className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-bold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:opacity-40"
            >
              {busy === "publish" ? <Loader2 className="size-4 animate-spin" /> : <Send className="size-4" />}
              Publiceren
            </button>
          </div>
        </section>

        {preview && (
          <section className="mt-6 rounded-xl border border-line bg-white p-6 shadow-card">
            <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <p className="text-[10px] font-bold uppercase tracking-[0.1em] text-brand-500">Fictieve preview</p>
                <h3 className="mt-1 text-sm font-bold text-brand-900">{preview.subject}</h3>
                <p className="mt-1 text-[11px] text-slate-400">{preview.preheader}</p>
              </div>
              <div className="flex rounded-lg border border-line bg-slate-50 p-1" role="group" aria-label="Previewmodus">
                {([
                  ["desktop", Monitor, "Desktop"],
                  ["mobile", Smartphone, "Mobiel"],
                  ["dark", Moon, "Donker"],
                  ["text", Type, "Tekst"],
                ] as const).map(([mode, Icon, label]) => (
                  <button
                    key={mode}
                    type="button"
                    aria-label={label}
                    aria-pressed={previewMode === mode}
                    onClick={() => setPreviewMode(mode)}
                    className={`flex size-9 items-center justify-center rounded-md ${
                      previewMode === mode ? "bg-white text-brand-700 shadow-sm" : "text-slate-400"
                    }`}
                  >
                    <Icon className="size-4" />
                  </button>
                ))}
              </div>
            </div>
            {previewMode === "text" ? (
              <pre className="mt-5 max-h-[620px] overflow-auto whitespace-pre-wrap rounded-lg border border-line bg-slate-50 p-5 font-sans text-xs leading-6 text-slate-700">
                {preview.text}
              </pre>
            ) : (
              <div className={`mt-5 overflow-auto rounded-lg border border-line p-4 ${
                previewMode === "dark" ? "bg-slate-950" : "bg-slate-100"
              }`}>
                <iframe
                  title={`Preview ${templateLabels[template.key]}`}
                  sandbox=""
                  srcDoc={preview.html}
                  className={`mx-auto h-[620px] border-0 bg-white transition-all ${
                    previewMode === "mobile" ? "w-[390px] max-w-full" : "w-full max-w-[760px]"
                  }`}
                />
              </div>
            )}
          </section>
        )}
      </div>
    </div>
  );
}

type EditableBranding = Omit<MailBranding, "contrastValidated">;
type BrandingRevision =
  | NonNullable<MailV2Workspace["branding"]["draft"]>
  | MailV2Workspace["branding"]["published"];

function editableBranding(revision: BrandingRevision): EditableBranding {
  return {
    clubName: revision.clubName,
    logoAssetPath: revision.logoAssetPath,
    fromName: revision.fromName,
    fromEmail: revision.fromEmail,
    replyToEmail: revision.replyToEmail,
    contactEmail: revision.contactEmail,
    clubAddressLine: revision.clubAddressLine,
    clubPostalCode: revision.clubPostalCode,
    clubCity: revision.clubCity,
    pickupName: revision.pickupName,
    pickupAddressLine: revision.pickupAddressLine,
    pickupPostalCode: revision.pickupPostalCode,
    pickupCity: revision.pickupCity,
    privacyUrl: revision.privacyUrl,
    primaryColor: revision.primaryColor,
    secondaryColor: revision.secondaryColor,
    accentColor: revision.accentColor,
    footerText: revision.footerText,
  };
}

export function MailV2BrandingPanel({ workspace }: { workspace: MailV2Workspace }) {
  const router = useRouter();
  const source = workspace.branding.draft ?? workspace.branding.published;
  const [branding, setBranding] = useState<EditableBranding>(editableBranding(source));
  const [dirty, setDirty] = useState(false);
  const [busy, setBusy] = useState<"save" | "publish" | null>(null);
  const [notice, setNotice] = useState<Notice>(null);

  useEffect(() => {
    setBranding(editableBranding(source));
    setDirty(false);
  }, [source]);

  function update<K extends keyof EditableBranding>(key: K, value: EditableBranding[K]) {
    setBranding((current) => ({ ...current, [key]: value }));
    setDirty(true);
    setNotice(null);
  }

  async function save() {
    setBusy("save");
    try {
      await postJson("/api/email/v2/branding", {
        action: "save",
        expectedHash: workspace.branding.draft?.contentHash ?? null,
        ...branding,
        primaryColor: branding.primaryColor.toUpperCase(),
        secondaryColor: branding.secondaryColor.toUpperCase(),
        accentColor: branding.accentColor.toUpperCase(),
      });
      setNotice({ tone: "success", text: "Brandingconcept opgeslagen en het contrast is opnieuw gecontroleerd." });
      setDirty(false);
      router.refresh();
    } catch (error) {
      setNotice({ tone: "error", text: error instanceof Error ? error.message : "Opslaan mislukt." });
    } finally {
      setBusy(null);
    }
  }

  async function publish() {
    if (!workspace.branding.draft || dirty) return;
    setBusy("publish");
    try {
      await postJson("/api/email/v2/branding", {
        action: "publish",
        revisionId: workspace.branding.draft.id,
        expectedHash: workspace.branding.draft.contentHash,
      });
      setNotice({ tone: "success", text: "Branding gepubliceerd voor toekomstige renders." });
      router.refresh();
    } catch (error) {
      setNotice({ tone: "error", text: error instanceof Error ? error.message : "Publiceren mislukt." });
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="grid items-start gap-6 xl:grid-cols-[minmax(0,1fr)_360px]">
      <section className="rounded-xl border border-line bg-white p-6 shadow-card">
        <StatusNotice notice={notice} />
        <div className="border-b border-line pb-5">
          <p className="text-[10px] font-bold uppercase tracking-[0.12em] text-brand-500">Operationele branding</p>
          <h2 className="mt-1 text-lg font-bold text-brand-900">Afzender, contact en afhalen</h2>
          <p className="mt-1 text-xs text-slate-500">Clubnaam, logo en privacyroute blijven vast; contactvelden zijn versioneerbaar.</p>
        </div>

        <fieldset disabled={Boolean(busy)} className="mt-5 grid gap-4 md:grid-cols-2">
          <label className="text-xs font-semibold text-ink">Clubnaam<input value={branding.clubName} readOnly className={fieldClass} /></label>
          <label className="text-xs font-semibold text-ink">Logoasset<input value={branding.logoAssetPath} readOnly className={fieldClass} /></label>
          <label className="text-xs font-semibold text-ink">Afzendernaam<input value={branding.fromName} onChange={(event) => update("fromName", event.target.value)} className={fieldClass} /></label>
          <label className="text-xs font-semibold text-ink">From-adres<input type="email" value={branding.fromEmail} onChange={(event) => update("fromEmail", event.target.value)} className={fieldClass} /></label>
          <label className="text-xs font-semibold text-ink">Reply-to<input type="email" value={branding.replyToEmail} onChange={(event) => update("replyToEmail", event.target.value)} className={fieldClass} /></label>
          <label className="text-xs font-semibold text-ink">Contactadres<input type="email" value={branding.contactEmail} onChange={(event) => update("contactEmail", event.target.value)} className={fieldClass} /></label>
          <label className="text-xs font-semibold text-ink">Verenigingsadres<input value={branding.clubAddressLine} onChange={(event) => update("clubAddressLine", event.target.value)} className={fieldClass} /></label>
          <div className="grid grid-cols-[120px_1fr] gap-3">
            <label className="text-xs font-semibold text-ink">Postcode<input value={branding.clubPostalCode} onChange={(event) => update("clubPostalCode", event.target.value.toUpperCase())} className={fieldClass} /></label>
            <label className="text-xs font-semibold text-ink">Plaats<input value={branding.clubCity} onChange={(event) => update("clubCity", event.target.value)} className={fieldClass} /></label>
          </div>
          <label className="text-xs font-semibold text-ink">Afhaalnaam<input value={branding.pickupName} onChange={(event) => update("pickupName", event.target.value)} className={fieldClass} /></label>
          <label className="text-xs font-semibold text-ink">Afhaaladres<input value={branding.pickupAddressLine} onChange={(event) => update("pickupAddressLine", event.target.value)} className={fieldClass} /></label>
          <div className="grid grid-cols-[120px_1fr] gap-3 md:col-start-2">
            <label className="text-xs font-semibold text-ink">Postcode<input value={branding.pickupPostalCode} onChange={(event) => update("pickupPostalCode", event.target.value.toUpperCase())} className={fieldClass} /></label>
            <label className="text-xs font-semibold text-ink">Plaats<input value={branding.pickupCity} onChange={(event) => update("pickupCity", event.target.value)} className={fieldClass} /></label>
          </div>
          <label className="text-xs font-semibold text-ink md:col-span-2">Privacyroute<input value={branding.privacyUrl} readOnly className={fieldClass} /></label>
          <label className="text-xs font-semibold text-ink md:col-span-2">Footer<textarea value={branding.footerText} onChange={(event) => update("footerText", event.target.value)} maxLength={1_000} className={`${fieldClass} h-24 py-3`} /></label>
          {([
            ["primaryColor", "Primair"],
            ["secondaryColor", "Secundair"],
            ["accentColor", "Accent"],
          ] as const).map(([key, label]) => (
            <label key={key} className="text-xs font-semibold text-ink">
              {label}
              <span className="mt-2 flex h-11 items-center gap-3 rounded-lg border border-line px-3">
                <input type="color" value={branding[key]} onChange={(event) => update(key, event.target.value.toUpperCase())} className="size-7 border-0 bg-transparent p-0" />
                <input value={branding[key]} onChange={(event) => update(key, event.target.value.toUpperCase())} maxLength={7} className="min-w-0 flex-1 font-mono text-xs uppercase outline-none" />
              </span>
            </label>
          ))}
        </fieldset>

        <div className="mt-6 flex flex-col-reverse gap-2 border-t border-line pt-5 sm:flex-row sm:justify-end">
          <button type="button" onClick={() => void save()} disabled={Boolean(busy) || !dirty} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-brand-200 px-4 text-xs font-bold text-brand-700 disabled:opacity-40">
            {busy === "save" ? <Loader2 className="size-4 animate-spin" /> : <Save className="size-4" />} Concept opslaan
          </button>
          <button type="button" onClick={() => void publish()} disabled={Boolean(busy) || dirty || !workspace.branding.draft || !workspace.branding.draft.contrastValidated} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-bold text-white disabled:opacity-40">
            {busy === "publish" ? <Loader2 className="size-4 animate-spin" /> : <Send className="size-4" />} Publiceren
          </button>
        </div>
      </section>

      <aside className="space-y-6">
        <section className="rounded-xl border border-line bg-white p-6 shadow-card">
          <div className="flex items-center gap-3">
            <span className="flex size-10 items-center justify-center rounded-xl bg-brand-50 text-brand-700"><Palette className="size-5" /></span>
            <div><h2 className="text-sm font-bold text-brand-900">Visuele preview</h2><p className="mt-1 text-[11px] text-slate-400">Vaste Duindorp SV-identiteit</p></div>
          </div>
          <div className="mt-5 overflow-hidden rounded-xl border border-line">
            <div style={{ backgroundColor: branding.secondaryColor }} className="flex h-24 items-center px-5">
              {/* eslint-disable-next-line @next/next/no-img-element */}
              <img src={branding.logoAssetPath} alt="Duindorp SV" className="size-14 object-contain" />
            </div>
            <div className="p-5">
              <p className="text-sm font-bold text-brand-900">{branding.fromName}</p>
              <p className="mt-1 text-xs text-slate-500">{branding.fromEmail}</p>
              <span style={{ backgroundColor: branding.primaryColor }} className="mt-4 inline-flex rounded-lg px-4 py-2 text-xs font-bold text-white">Voorbeeldknop</span>
              <p className="mt-5 border-t border-line pt-4 text-[10px] leading-5 text-slate-400">{branding.footerText}</p>
            </div>
          </div>
        </section>
        <section className={`rounded-xl border p-5 ${
          workspace.branding.draft?.contrastValidated ?? workspace.branding.published.contrastValidated
            ? "border-emerald-200 bg-emerald-50"
            : "border-red-200 bg-red-50"
        }`}>
          <div className="flex gap-3">
            <ShieldCheck className="mt-0.5 size-5 shrink-0 text-brand-700" />
            <div>
              <p className="text-xs font-bold text-brand-900">Contrastpublicatie</p>
              <p className="mt-1 text-[11px] leading-5 text-slate-600">Primair, secundair en accent moeten elk minimaal 4,5:1 contrast met wit hebben. De server berekent dit opnieuw bij opslaan.</p>
            </div>
          </div>
        </section>
      </aside>
    </div>
  );
}
