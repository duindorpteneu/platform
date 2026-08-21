"use client";

import { ArrowRight, Loader2, Mail, RefreshCw } from "lucide-react";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";

function remainingLabel(deadline: string, now: number) {
  const seconds = Math.max(0, Math.ceil((Date.parse(deadline) - now) / 1_000));
  return `${String(Math.floor(seconds / 60)).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
}

export function ParentCodeForm({
  maskedEmail,
  expiresAt,
  cooldownUntil,
}: {
  maskedEmail: string;
  expiresAt: string;
  cooldownUntil: string;
}) {
  const router = useRouter();
  const [now, setNow] = useState(() => Date.now());
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [attemptsRemaining, setAttemptsRemaining] = useState<number | null>(null);
  const [loading, setLoading] = useState(false);
  const [resending, setResending] = useState(false);
  const [confirmNew, setConfirmNew] = useState(false);

  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 1_000);
    return () => window.clearInterval(timer);
  }, []);

  const expired = Date.parse(expiresAt) <= now;
  const coolingDown = Date.parse(cooldownUntil) > now;

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setError(null);
    setAttemptsRemaining(null);
    setLoading(true);
    try {
      const response = await fetch("/api/parent-auth/verify-code", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Duindorp-CSRF": "same-origin",
        },
        body: JSON.stringify({ code }),
      });
      const payload = await response.json() as {
        error?: string;
        attemptsRemaining?: number;
      };
      if (!response.ok) {
        if (typeof payload.attemptsRemaining === "number") {
          setAttemptsRemaining(payload.attemptsRemaining);
        }
        throw new Error(
          payload.error ?? "Deze code klopt niet of is niet meer geldig.",
        );
      }
      router.push("/mijn-tenue");
    } catch (cause) {
      setError(cause instanceof Error
        ? cause.message
        : "De code kon niet worden gecontroleerd.");
    } finally {
      setLoading(false);
    }
  }

  async function requestAgain(forceNew = false) {
    setError(null);
    setResending(true);
    try {
      const response = await fetch("/api/parent-auth/request-code", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Duindorp-CSRF": "same-origin",
        },
        body: JSON.stringify({ resend: true, forceNew }),
      });
      const payload = await response.json() as { error?: string };
      if (!response.ok) {
        throw new Error(payload.error ?? "De e-mail kon niet worden verstuurd.");
      }
      setConfirmNew(false);
      router.refresh();
    } catch (cause) {
      setError(cause instanceof Error
        ? cause.message
        : "De e-mail kon niet worden verstuurd.");
    } finally {
      setResending(false);
    }
  }

  return (
    <form
      className="rounded-2xl border border-line bg-white p-6 text-left shadow-card"
      onSubmit={submit}
    >
      <div className="flex items-start gap-3 rounded-xl bg-brand-50 p-4">
        <Mail aria-hidden="true" className="mt-0.5 size-5 shrink-0 text-brand-700" />
        <p className="text-xs leading-5 text-slate-600">
          Wij hebben een verificatiecode gestuurd naar<br />
          <strong className="text-brand-900">{maskedEmail}</strong>
        </p>
      </div>
      <label
        className="mt-6 block text-xs font-semibold text-ink"
        htmlFor="parent-code"
      >
        Zescijferige verificatiecode
      </label>
      <input
        autoComplete="one-time-code"
        className="mt-2 h-14 w-full rounded-lg border border-line text-center text-2xl font-bold tracking-[0.45em] text-brand-900 outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100"
        disabled={expired}
        id="parent-code"
        inputMode="numeric"
        maxLength={6}
        onChange={(event) => setCode(
          event.target.value.replace(/\D/gu, "").slice(0, 6),
        )}
        pattern="[0-9]{6}"
        required
        value={code}
      />
      <p className="mt-2 text-center text-xs font-semibold text-slate-500">
        {expired
          ? "Deze code is niet meer geldig."
          : `Code geldig: ${remainingLabel(expiresAt, now)}`}
      </p>
      {error && <p className="mt-3 text-xs text-danger">{error}</p>}
      {attemptsRemaining !== null && attemptsRemaining > 0 && (
        <p className="mt-2 text-xs text-slate-500">
          Nog {attemptsRemaining} {attemptsRemaining === 1 ? "poging" : "pogingen"}.
        </p>
      )}
      <button
        className="mt-5 flex h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 text-sm font-semibold text-white hover:bg-brand-900 disabled:bg-slate-200 disabled:text-slate-400"
        disabled={loading || expired || code.length !== 6}
      >
        {loading && <Loader2 aria-hidden="true" className="size-4 animate-spin" />}
        {loading ? "Controleren…" : "Ga naar mijn tenue"}
        <ArrowRight aria-hidden="true" className="size-4" />
      </button>

      <div className="mt-6 border-t border-line pt-5 text-center">
        <p className="text-xs font-semibold text-ink">Geen mail ontvangen?</p>
        <button
          className="mt-2 inline-flex min-h-10 items-center justify-center gap-2 rounded-lg px-3 text-xs font-semibold text-brand-700 hover:bg-brand-50 disabled:cursor-wait disabled:text-slate-400"
          disabled={resending || coolingDown || expired}
          onClick={() => requestAgain(false)}
          type="button"
        >
          {resending
            ? <Loader2 aria-hidden="true" className="size-4 animate-spin" />
            : <RefreshCw aria-hidden="true" className="size-4" />}
          {coolingDown
            ? `Nieuwe mail versturen over ${remainingLabel(cooldownUntil, now)}`
            : "Verificatiemail opnieuw versturen"}
        </button>
        <p className="mt-2 text-[11px] leading-5 text-slate-400">
          Zolang de code geldig is, ontvang je dezelfde code opnieuw.
        </p>
        {!confirmNew ? (
          <button
            className="mt-3 text-[11px] font-semibold text-slate-500 underline hover:text-brand-700"
            onClick={() => setConfirmNew(true)}
            type="button"
          >
            Nieuwe code aanmaken
          </button>
        ) : (
          <div className="mt-3 rounded-lg border border-warning/30 bg-warning/10 p-3 text-left">
            <p className="text-xs leading-5 text-slate-700">
              Hiermee vervalt je huidige verificatiecode.
            </p>
            <div className="mt-2 flex gap-2">
              <button
                className="h-9 rounded-lg bg-brand-700 px-3 text-xs font-semibold text-white"
                disabled={resending}
                onClick={() => requestAgain(true)}
                type="button"
              >
                Nieuwe code sturen
              </button>
              <button
                className="h-9 rounded-lg border border-line px-3 text-xs font-semibold text-slate-600"
                onClick={() => setConfirmNew(false)}
                type="button"
              >
                Annuleren
              </button>
            </div>
          </div>
        )}
      </div>
    </form>
  );
}
