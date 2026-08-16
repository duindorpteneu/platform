"use client";

import {
  AlertTriangle,
  CheckCircle2,
  Loader2,
  MailCheck,
  RefreshCw,
  ShieldAlert,
} from "lucide-react";
import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";
import type { DeliveryNotificationProposal } from "@/lib/delivery-notification-contract";

type ApiError = { error?: string };

const reasonLabels: Record<string, string> = {
  "notification.ready": "Betaald, hard gereserveerd en bereikbaar",
  "notification.staff_not_selected": "Bewust niet geselecteerd",
  "notification.no_active_parent_grant": "Geen actieve oudertoegang",
  "notification.readiness_event_exists": "Afhaalbericht bestaat al",
  "notification.readiness_suppressed": "Afhaalbericht is onderdrukt",
  "notification.mail_v2_inactive": "Mail-v2 is nog niet actief",
  "notification.template_unavailable": "Gepubliceerde template of branding ontbreekt",
  "notification.allocation_not_ready": "Reservering is niet meer afhaalklaar",
  "notification.payment_not_valid": "Betaling is niet meer geldig",
  "notification.source_mismatch": "Bron- of seizoensbinding klopt niet",
  "notification.events_enqueued": "Afhaalbericht is veilig klaargezet",
};

function newRequestId() {
  return crypto.randomUUID();
}

export function DeliveryNotificationProposalPanel({
  draftId,
}: {
  draftId: string;
}) {
  const [proposal, setProposal] = useState<DeliveryNotificationProposal | null>(
    null,
  );
  const [selected, setSelected] = useState<string[]>([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const requestId = useRef(newRequestId());

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const response = await fetch(
        `/api/stock/drafts/${draftId}/notifications`,
        { cache: "no-store" },
      );
      const payload = await response.json() as
        DeliveryNotificationProposal & ApiError;
      if (!response.ok) {
        throw new Error(
          payload.error ?? "Het notificatievoorstel kon niet worden geladen.",
        );
      }
      setProposal(payload);
      setSelected(payload.status === "open"
        ? payload.items
          .filter((item) => item.selectedByDefault)
          .map((item) => item.id)
        : []);
    } catch (loadError) {
      setError(loadError instanceof Error
        ? loadError.message
        : "Het notificatievoorstel kon niet worden geladen.");
    } finally {
      setLoading(false);
    }
  }, [draftId]);

  useEffect(() => {
    requestId.current = newRequestId();
    void load();
  }, [load]);

  async function confirm() {
    if (!proposal || proposal.status !== "open") return;
    const eligibleIds = proposal.items
      .filter((item) => item.classification === "eligible")
      .map((item) => item.id);
    const excludedItemIds = eligibleIds.filter((id) => !selected.includes(id));
    if (!window.confirm(
      `Bevestig ${selected.length} geselecteerde afhaalregel${selected.length === 1 ? "" : "s"}? De doelgroep wordt transactioneel opnieuw gecontroleerd.`,
    )) return;
    setSaving(true);
    setError(null);
    setSuccess(null);
    try {
      const response = await fetch(
        `/api/stock/drafts/${draftId}/notifications`,
        {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "X-Duindorp-CSRF": "same-origin",
          },
          body: JSON.stringify({
            proposalId: proposal.id,
            expectedRevision: proposal.eligibilityRevision,
            excludedItemIds,
            requestId: requestId.current,
          }),
        },
      );
      const payload = await response.json() as {
        eligibleCount?: number;
        skippedCount?: number;
        blockedCount?: number;
        parentGroupCount?: number;
        error?: string;
      };
      if (!response.ok) {
        throw new Error(
          payload.error ?? "Het notificatievoorstel kon niet worden bevestigd.",
        );
      }
      requestId.current = newRequestId();
      setSuccess(
        `${payload.eligibleCount ?? 0} geschikt, ${payload.skippedCount ?? 0} overgeslagen en ${payload.blockedCount ?? 0} geblokkeerd; ${payload.parentGroupCount ?? 0} oudergroep${payload.parentGroupCount === 1 ? "" : "en"} is veilig klaargezet.`,
      );
      await load();
    } catch (saveError) {
      setError(saveError instanceof Error
        ? saveError.message
        : "Het notificatievoorstel kon niet worden bevestigd.");
    } finally {
      setSaving(false);
    }
  }

  if (loading && !proposal) {
    return (
      <div className="border-t border-line p-6" role="status">
        <span className="inline-flex items-center gap-2 text-xs text-slate-500">
          <Loader2 className="size-4 animate-spin" />
          Notificatievoorstel controleren…
        </span>
      </div>
    );
  }

  return (
    <section
      className="border-t border-line bg-slate-50/70 p-6"
      aria-labelledby={`delivery-notification-${draftId}`}
    >
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="text-xs font-bold uppercase tracking-[0.12em] text-slate-500">
            Stap 3 · expliciete communicatie
          </p>
          <h3
            id={`delivery-notification-${draftId}`}
            className="mt-1 text-base font-bold text-brand-900"
          >
            Afhaalnotificatievoorstel
          </h3>
          <p className="mt-1 max-w-2xl text-xs text-slate-500">
            Boeken verstuurt niets. Alleen geselecteerde, opnieuw gecontroleerde
            betaalde reserveringen worden per ouderaccount geconsolideerd.
            Onbetaalde beschikbaarheid valt buiten dit voorstel en geeft nooit
            een voorraadgarantie.
          </p>
        </div>
        <button
          type="button"
          onClick={() => void load()}
          disabled={loading || saving}
          className="inline-flex h-9 items-center gap-2 rounded-lg border border-line bg-white px-3 text-xs font-semibold text-slate-600 hover:border-brand-500 disabled:opacity-60"
        >
          <RefreshCw className={`size-3.5 ${loading ? "animate-spin" : ""}`} />
          Hercontroleren
        </button>
      </div>

      {error && (
        <div
          role="alert"
          className="mt-4 flex items-start gap-2 rounded-xl border border-red-100 bg-red-50 p-4 text-xs text-danger"
        >
          <AlertTriangle className="size-4 shrink-0" />
          {error}
        </div>
      )}
      {success && (
        <div
          role="status"
          className="mt-4 flex items-start gap-2 rounded-xl border border-emerald-100 bg-emerald-50 p-4 text-xs text-success"
        >
          <CheckCircle2 className="size-4 shrink-0" />
          {success}
        </div>
      )}

      {proposal && (
        <>
          <div className="mt-4 grid gap-3 sm:grid-cols-4">
            {[
              ["Geschikt", proposal.eligibleCount, "text-success"],
              ["Overgeslagen", proposal.skippedCount, "text-slate-600"],
              ["Geblokkeerd", proposal.blockedCount, "text-danger"],
              ["Oudergroepen", proposal.parentGroupCount, "text-brand-700"],
            ].map(([label, count, tone]) => (
              <div
                key={String(label)}
                className="rounded-xl border border-line bg-white p-3"
              >
                <p className="text-xs font-bold uppercase tracking-[0.08em] text-slate-500">
                  {label}
                </p>
                <p className={`mt-1 text-xl font-bold ${tone}`}>
                  {count}
                </p>
              </div>
            ))}
          </div>

          {proposal.items.some((item) => (
            item.reasonCode === "notification.mail_v2_inactive"
          )) && (
            <div className="mt-4 flex flex-col gap-3 rounded-xl border border-amber-200 bg-amber-50 p-4 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <p className="text-xs font-bold text-amber-950">
                  Mail-v2 moet eenmalig door een beheerder worden geactiveerd
                </p>
                <p className="mt-1 text-xs leading-5 text-amber-900">
                  Open het e-mailcentrum, publiceer de veilige systeemtemplates
                  en activeer Mail-v2. Deze levering blijft daarna hercontroleerbaar.
                </p>
              </div>
              <Link
                href="/backoffice/emails?tab=templates#mail-v2-cutover"
                className="inline-flex min-h-10 shrink-0 items-center justify-center rounded-lg bg-brand-700 px-4 text-xs font-bold text-white hover:bg-brand-900"
              >
                Naar Mail-v2-activatie
              </Link>
            </div>
          )}

          <div className="mt-4 space-y-2">
            {proposal.items.length === 0 ? (
              <p className="rounded-xl border border-dashed border-line bg-white p-5 text-center text-xs text-slate-500">
                Deze levering heeft geen nieuwe harde allocaties opgeleverd.
              </p>
            ) : proposal.items.map((item) => {
              const eligible = item.classification === "eligible";
              const checked = selected.includes(item.id);
              return (
                <label
                  key={item.id}
                  className={`flex min-h-14 items-center gap-3 rounded-xl border bg-white px-4 py-3 ${
                    item.classification === "blocked"
                      ? "border-red-100"
                      : item.classification === "skipped"
                        ? "border-slate-200"
                        : "border-emerald-100"
                  }`}
                >
                  <input
                    type="checkbox"
                    checked={checked}
                    disabled={proposal.status !== "open" || !eligible}
                    onChange={() => setSelected((current) => checked
                      ? current.filter((id) => id !== item.id)
                      : [...current, item.id])}
                    className="size-4 rounded border-slate-300 text-brand-700 focus:ring-brand-500"
                  />
                  <span className="min-w-0 flex-1">
                    <span className="block text-xs font-semibold text-ink">
                      {item.productName} · maat {item.size}
                    </span>
                    <span className="mt-1 block text-xs text-slate-500">
                      {reasonLabels[item.reasonCode] ?? item.reasonCode}
                    </span>
                  </span>
                  <span className={`rounded-full px-2.5 py-1 text-xs font-bold ${
                    item.classification === "eligible"
                      ? "bg-emerald-50 text-success"
                      : item.classification === "blocked"
                        ? "bg-red-50 text-danger"
                        : "bg-slate-100 text-slate-600"
                  }`}>
                    {item.classification === "eligible"
                      ? proposal.status === "confirmed"
                        ? "Klaargezet"
                        : "Geschikt"
                      : item.classification === "blocked"
                        ? "Geblokkeerd"
                        : "Overgeslagen"}
                  </span>
                </label>
              );
            })}
          </div>

          {proposal.status === "open" ? (
            <div className="mt-4 flex flex-wrap items-center justify-between gap-3">
              <p className="inline-flex items-center gap-2 text-xs text-slate-500">
                <ShieldAlert className="size-3.5" />
                Betaling, reservering, seizoen, oudergrant, template en
                suppressie worden bij bevestigen opnieuw gecontroleerd.
              </p>
              <button
                type="button"
                onClick={() => void confirm()}
                disabled={saving}
                className="inline-flex h-11 items-center justify-center gap-2 rounded-lg bg-brand-700 px-5 text-sm font-semibold text-white hover:bg-brand-900 disabled:bg-slate-300"
              >
                {saving
                  ? <Loader2 className="size-4 animate-spin" />
                  : <MailCheck className="size-4" />}
                Selectie bevestigen
              </button>
            </div>
          ) : (
            <p className="mt-4 inline-flex items-center gap-2 text-xs font-semibold text-success">
              <CheckCircle2 className="size-4" />
              Dit voorstel is definitief bevestigd en blijft auditbaar.
            </p>
          )}
        </>
      )}
    </section>
  );
}
