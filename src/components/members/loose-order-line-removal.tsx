"use client";

import { AlertTriangle, Loader2, Trash2, X } from "lucide-react";
import { useRouter } from "next/navigation";
import { useState } from "react";

export function LooseOrderLineRemoval({
  orderLineId,
  article,
}: {
  orderLineId: string;
  article: string;
}) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [requestId, setRequestId] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function close() {
    if (busy) return;
    setOpen(false);
    setReason("");
    setRequestId(null);
    setError(null);
  }

  async function remove() {
    const id = requestId ?? crypto.randomUUID();
    setRequestId(id);
    setBusy(true);
    setError(null);
    try {
      const response = await fetch("/api/orders/loose-lines/remove", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Duindorp-CSRF": "same-origin",
          "X-Correlation-Id": crypto.randomUUID(),
        },
        body: JSON.stringify({ orderLineId, reason, requestId: id }),
      });
      const payload = await response.json() as { error?: string };
      if (!response.ok) {
        throw new Error(payload.error ?? "Verwijderen mislukt.");
      }
      setBusy(false);
      close();
      router.refresh();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "Verwijderen mislukt.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        className="inline-flex min-h-9 items-center gap-1.5 rounded-lg border border-red-200 px-2.5 text-[10px] font-semibold text-danger hover:bg-red-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500"
      >
        <Trash2 className="size-3.5" aria-hidden="true" />
        Verwijderen
      </button>
      {open && (
        <div
          role="dialog"
          aria-modal="true"
          aria-labelledby={`remove-line-${orderLineId}`}
          className="fixed inset-0 z-50 flex items-end justify-center bg-slate-950/55 p-4 sm:items-center"
        >
          <div className="w-full max-w-md rounded-2xl bg-white p-5 shadow-2xl">
            <div className="flex items-start justify-between gap-4">
              <div>
                <h2 id={`remove-line-${orderLineId}`} className="text-base font-bold text-brand-900">
                  Los artikel verwijderen
                </h2>
                <p className="mt-2 text-xs leading-5 text-slate-500">
                  <strong>{article}</strong> wordt geannuleerd. Het pakket,
                  pakketbedrag en de historische registratie blijven intact.
                </p>
              </div>
              <button type="button" onClick={close} aria-label="Sluiten" className="flex size-9 shrink-0 items-center justify-center rounded-lg border border-line text-slate-500">
                <X className="size-4" />
              </button>
            </div>
            <label htmlFor={`remove-reason-${orderLineId}`} className="mt-5 block text-xs font-semibold text-ink">
              Reden
            </label>
            <textarea
              id={`remove-reason-${orderLineId}`}
              value={reason}
              onChange={(event) => {
                setReason(event.target.value);
                setRequestId(null);
              }}
              rows={3}
              minLength={3}
              maxLength={500}
              placeholder="Bijvoorbeeld: per ongeluk als los artikel toegevoegd"
              className="mt-2 w-full rounded-lg border border-line px-3 py-2 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100"
            />
            <p className="mt-1 text-[10px] text-slate-400">Neem geen persoonsgegevens op in de reden.</p>
            {error && (
              <p role="alert" className="mt-3 flex gap-2 rounded-lg border border-red-100 bg-red-50 p-3 text-xs text-danger">
                <AlertTriangle className="mt-0.5 size-4 shrink-0" />{error}
              </p>
            )}
            <div className="mt-5 flex justify-end gap-2">
              <button type="button" onClick={close} disabled={busy} className="h-10 rounded-lg border border-line px-4 text-xs font-semibold text-slate-600">Annuleren</button>
              <button type="button" onClick={() => void remove()} disabled={busy || reason.trim().length < 3} className="inline-flex h-10 items-center gap-2 rounded-lg bg-red-700 px-4 text-xs font-semibold text-white disabled:bg-slate-300">
                {busy ? <Loader2 className="size-4 animate-spin" /> : <Trash2 className="size-4" />}
                Definitief verwijderen
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
