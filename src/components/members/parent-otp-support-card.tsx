"use client";

import { AlertTriangle, Loader2, MailCheck, RefreshCw } from "lucide-react";
import { useRouter } from "next/navigation";
import { useState } from "react";
import type {
  ParentOtpSupport,
  ParentOtpSupportActionResponse,
} from "@/lib/parent-otp-support-contract";

const deliveryLabels: Record<
  NonNullable<ParentOtpSupport["lastDeliveryStatus"]>,
  string
> = {
  provider_accepted: "Geaccepteerd door mailserver",
  provider_rejected: "Geweigerd door provider",
  delivery_uncertain: "Aflevering niet bevestigd",
  configuration_error: "Providerconfiguratie niet beschikbaar",
  disabled: "E-mailverzending uitgeschakeld",
  render_failed: "E-mail kon niet worden opgebouwd",
};

function moment(value: string | null) {
  if (!value) return "Nog nooit";
  return new Intl.DateTimeFormat("nl-NL", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    timeZone: "Europe/Amsterdam",
  }).format(new Date(value));
}

function outcomeMessage(result: ParentOtpSupportActionResponse) {
  if (result.outcome === "provider_accepted") {
    return result.reused
      ? "Dezelfde geldige verificatiecode is opnieuw aan de mailserver overgedragen."
      : "Een nieuwe verificatiecode is aan de mailserver overgedragen.";
  }
  return `De verzendpoging is vastgelegd: ${deliveryLabels[result.outcome]}.`;
}

export function ParentOtpSupportCard({
  support,
}: {
  support: ParentOtpSupport;
}) {
  const router = useRouter();
  const [loading, setLoading] = useState<"resend" | "reset" | null>(null);
  const [confirmReset, setConfirmReset] = useState(false);
  const [feedback, setFeedback] = useState<{
    kind: "success" | "error";
    text: string;
  } | null>(null);

  async function run(mode: "resend" | "reset") {
    setFeedback(null);
    setLoading(mode);
    try {
      const response = await fetch("/api/parent-auth/support", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Duindorp-CSRF": "same-origin",
        },
        body: JSON.stringify({
          parentAccountId: support.parentAccountId,
          mode,
        }),
      });
      const payload = await response.json() as ParentOtpSupportActionResponse & {
        error?: string;
      };
      if (!response.ok) {
        throw new Error(
          payload.error ?? "De verificatiemail kon niet worden verwerkt.",
        );
      }
      setFeedback({ kind: "success", text: outcomeMessage(payload) });
      setConfirmReset(false);
      router.refresh();
    } catch (cause) {
      setFeedback({
        kind: "error",
        text: cause instanceof Error
          ? cause.message
          : "De verificatiemail kon niet worden verwerkt.",
      });
    } finally {
      setLoading(null);
    }
  }

  return (
    <section className="p-5" aria-labelledby="parent-otp-support-title">
      <div className="flex items-center gap-2">
        <MailCheck aria-hidden="true" className="size-4 text-brand-500" />
        <h3
          className="text-xs font-bold uppercase tracking-[0.08em] text-slate-400"
          id="parent-otp-support-title"
        >
          Portaaltoegang
        </h3>
      </div>
      <dl className="mt-4 space-y-2 text-xs">
        <div className="flex justify-between gap-3">
          <dt className="text-slate-400">Status</dt>
          <dd className="font-semibold text-success">Actief</dd>
        </div>
        <div className="flex justify-between gap-3">
          <dt className="text-slate-400">Loginadres</dt>
          <dd className="text-right font-semibold text-ink">
            {support.loginEmailMasked}
          </dd>
        </div>
        <div className="flex justify-between gap-3">
          <dt className="text-slate-400">Laatste code aangevraagd</dt>
          <dd className="text-right font-semibold text-ink">
            {moment(support.lastCodeRequestedAt)}
          </dd>
        </div>
        <div className="flex justify-between gap-3">
          <dt className="text-slate-400">Laatste afleverpoging</dt>
          <dd className="max-w-[12rem] text-right text-ink">
            <span className="block font-semibold">
              {support.lastDeliveryStatus
                ? deliveryLabels[support.lastDeliveryStatus]
                : "Nog geen poging"}
            </span>
            {support.lastDeliveryAttemptAt && (
              <span className="mt-0.5 block text-[10px] text-slate-400">
                {moment(support.lastDeliveryAttemptAt)}
              </span>
            )}
          </dd>
        </div>
        <div className="flex justify-between gap-3">
          <dt className="text-slate-400">Code geldig tot</dt>
          <dd className="text-right font-semibold text-ink">
            {support.codeExpiresAt ? moment(support.codeExpiresAt) : "Geen actieve code"}
          </dd>
        </div>
        <div className="flex justify-between gap-3">
          <dt className="text-slate-400">Laatste succesvolle login</dt>
          <dd className="text-right font-semibold text-ink">
            {moment(support.lastSuccessfulLoginAt)}
          </dd>
        </div>
        <div className="flex justify-between gap-3">
          <dt className="text-slate-400">Gekoppelde kinderen</dt>
          <dd className="text-right font-semibold text-ink">
            {support.linkedChildren.length}
          </dd>
        </div>
      </dl>

      <div className="mt-4 space-y-2">
        <button
          className="flex min-h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 px-3 text-xs font-semibold text-white hover:bg-brand-900 disabled:cursor-wait disabled:bg-slate-300"
          disabled={loading !== null}
          onClick={() => void run("resend")}
          type="button"
        >
          {loading === "resend"
            ? <Loader2 aria-hidden="true" className="size-4 animate-spin" />
            : <RefreshCw aria-hidden="true" className="size-4" />}
          Verificatiemail opnieuw versturen
        </button>
        {!confirmReset ? (
          <button
            className="min-h-10 w-full rounded-lg border border-line px-3 text-xs font-semibold text-slate-600 hover:border-brand-300 hover:text-brand-700"
            disabled={loading !== null}
            onClick={() => setConfirmReset(true)}
            type="button"
          >
            Alle codes intrekken + nieuwe sturen
          </button>
        ) : (
          <div className="rounded-lg border border-amber-200 bg-amber-50 p-3">
            <div className="flex gap-2">
              <AlertTriangle
                aria-hidden="true"
                className="mt-0.5 size-4 shrink-0 text-warning"
              />
              <p className="text-xs leading-5 text-amber-900">
                Hiermee vervalt de huidige verificatiecode op alle apparaten.
              </p>
            </div>
            <div className="mt-3 flex gap-2">
              <button
                className="h-9 flex-1 rounded-lg bg-brand-700 px-3 text-xs font-semibold text-white disabled:bg-slate-300"
                disabled={loading !== null}
                onClick={() => void run("reset")}
                type="button"
              >
                {loading === "reset" ? "Versturen…" : "Intrekken en sturen"}
              </button>
              <button
                className="h-9 rounded-lg border border-amber-300 px-3 text-xs font-semibold text-amber-900"
                disabled={loading !== null}
                onClick={() => setConfirmReset(false)}
                type="button"
              >
                Annuleren
              </button>
            </div>
          </div>
        )}
      </div>

      {feedback && (
        <p
          aria-live="polite"
          className={`mt-3 rounded-lg p-3 text-xs leading-5 ${feedback.kind === "success" ? "bg-emerald-50 text-emerald-800" : "bg-red-50 text-danger"}`}
        >
          {feedback.text}
        </p>
      )}
      <p className="mt-3 text-[10px] leading-4 text-slate-400">
        Beheerders kunnen de code of directe inloglink nooit bekijken of kopiëren.
      </p>
    </section>
  );
}
