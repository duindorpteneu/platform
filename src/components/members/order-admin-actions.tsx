"use client";

import { AlertTriangle, CheckCircle2, KeyRound, Loader2, RotateCw, Undo2 } from "lucide-react";
import { useRouter } from "next/navigation";
import { useMemo, useState } from "react";

type PickedLine = { id: string; article: string; size: string };

export function OrderAdminActions({ orderId, paid, qrStatus, pickedLines }: {
  orderId: string;
  paid: boolean;
  qrStatus: "Actief" | "Ingetrokken" | "Niet aangemaakt";
  pickedLines: PickedLine[];
}) {
  const router = useRouter();
  const [reason, setReason] = useState("");
  const [correctionReason, setCorrectionReason] = useState("");
  const [targetStatus, setTargetStatus] = useState<"ready_for_pickup" | "backorder">("ready_for_pickup");
  const [selected, setSelected] = useState<string[]>([]);
  const [busy, setBusy] = useState<"qr" | "correction" | null>(null);
  const [message, setMessage] = useState<{ tone: "success" | "error"; text: string } | null>(null);
  const canRotate = paid && qrStatus !== "Niet aangemaakt";
  const selectedSet = useMemo(() => new Set(selected), [selected]);

  async function manageQr(action: "rotate" | "revoke") {
    setBusy("qr"); setMessage(null);
    try {
      const response = await fetch("/api/qr/rotate", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ orderId, action, reason }),
      });
      const payload = await response.json() as { error?: string };
      if (!response.ok) throw new Error(payload.error ?? "QR-actie mislukt.");
      setReason("");
      setMessage({ tone: "success", text: action === "rotate" ? "Nieuwe QR-versie is actief; de oude code is direct ongeldig." : "De QR-code is direct ingetrokken." });
      router.refresh();
    } catch (error) {
      setMessage({ tone: "error", text: error instanceof Error ? error.message : "QR-actie mislukt." });
    } finally { setBusy(null); }
  }

  async function correct() {
    setBusy("correction"); setMessage(null);
    try {
      const response = await fetch("/api/fulfilment/reverse", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ orderLineIds: selected, targetStatus, reason: correctionReason }),
      });
      const payload = await response.json() as { error?: string; correctedLines?: number };
      if (!response.ok) throw new Error(payload.error ?? "Correctie mislukt.");
      setSelected([]); setCorrectionReason("");
      setMessage({ tone: "success", text: `${payload.correctedLines ?? 0} uitgifteregel(s) gecorrigeerd met behoud van historie.` });
      router.refresh();
    } catch (error) {
      setMessage({ tone: "error", text: error instanceof Error ? error.message : "Correctie mislukt." });
    } finally { setBusy(null); }
  }

  return (
    <section className="p-5">
      <div className="flex items-center gap-2"><KeyRound className="size-4 text-brand-500" /><h3 className="text-xs font-bold uppercase tracking-[0.08em] text-slate-400">Beheeracties</h3></div>
      {message && <div role="status" className={`mt-4 flex gap-2 rounded-lg border p-3 text-xs leading-5 ${message.tone === "success" ? "border-emerald-100 bg-emerald-50 text-success" : "border-red-100 bg-red-50 text-danger"}`}>{message.tone === "success" ? <CheckCircle2 className="mt-0.5 size-4 shrink-0" /> : <AlertTriangle className="mt-0.5 size-4 shrink-0" />}{message.text}</div>}

      <div className="mt-4 rounded-lg border border-line p-4">
        <p className="text-xs font-bold text-brand-900">QR-code beveiligen</p>
        <p className="mt-1 text-[11px] leading-5 text-slate-500">Roteren maakt de oude code ongeldig. Intrekken laat bewust geen actieve code achter.</p>
        <label htmlFor="qr-reason" className="mt-3 block text-[11px] font-semibold text-ink">Verplichte reden</label>
        <textarea id="qr-reason" value={reason} onChange={(event) => setReason(event.target.value)} maxLength={500} rows={2} className="mt-1.5 w-full rounded-lg border border-line px-3 py-2 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" />
        {!paid && <p className="mt-2 text-[11px] text-warning">QR-rotatie is pas mogelijk na exacte betaling.</p>}
        <div className="mt-3 grid gap-2 sm:grid-cols-2">
          <button type="button" disabled={busy !== null || reason.trim().length < 4 || !canRotate} onClick={() => void manageQr("rotate")} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-3 text-xs font-semibold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:bg-slate-300">{busy === "qr" ? <Loader2 className="size-4 animate-spin" /> : <RotateCw className="size-4" />} {qrStatus === "Ingetrokken" ? "Nieuwe QR activeren" : "QR roteren"}</button>
          <button type="button" disabled={busy !== null || reason.trim().length < 4 || qrStatus !== "Actief"} onClick={() => void manageQr("revoke")} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-red-200 px-3 text-xs font-semibold text-danger hover:bg-red-50 disabled:cursor-not-allowed disabled:border-line disabled:text-slate-300">QR intrekken</button>
        </div>
      </div>

      <div className="mt-4 rounded-lg border border-line p-4">
        <p className="text-xs font-bold text-brand-900">Foutieve uitgifte corrigeren</p>
        {pickedLines.length === 0 ? <p className="mt-2 text-[11px] leading-5 text-slate-500">Er zijn geen actieve uitgegeven regels die gecorrigeerd kunnen worden.</p> : <>
          <div className="mt-3 space-y-2">{pickedLines.map((line) => <label key={line.id} className="flex min-h-11 cursor-pointer items-center gap-3 rounded-lg bg-slate-50 px-3 py-2 text-xs"><input type="checkbox" checked={selectedSet.has(line.id)} onChange={() => setSelected((current) => selectedSet.has(line.id) ? current.filter((id) => id !== line.id) : [...current, line.id])} className="size-4 rounded border-slate-300 text-brand-700 focus:ring-brand-500" /><span className="font-semibold text-ink">{line.article} · {line.size}</span></label>)}</div>
          <label htmlFor="correction-target" className="mt-3 block text-[11px] font-semibold text-ink">Terugzetten naar</label>
          <select id="correction-target" value={targetStatus} onChange={(event) => setTargetStatus(event.target.value as typeof targetStatus)} className="mt-1.5 h-10 w-full rounded-lg border border-line bg-white px-3 text-xs outline-none focus:border-brand-500"><option value="ready_for_pickup">Af te halen — reservering behouden</option><option value="backorder">Nalevering — voorraad vrijgeven</option></select>
          <label htmlFor="correction-reason" className="mt-3 block text-[11px] font-semibold text-ink">Verplichte reden</label>
          <textarea id="correction-reason" value={correctionReason} onChange={(event) => setCorrectionReason(event.target.value)} maxLength={500} rows={2} className="mt-1.5 w-full rounded-lg border border-line px-3 py-2 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" />
          <button type="button" disabled={busy !== null || selected.length === 0 || correctionReason.trim().length < 4} onClick={() => void correct()} className="mt-3 inline-flex h-10 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 px-3 text-xs font-semibold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:bg-slate-300">{busy === "correction" ? <Loader2 className="size-4 animate-spin" /> : <Undo2 className="size-4" />} Geselecteerde uitgifte corrigeren</button>
        </>}
      </div>
    </section>
  );
}
