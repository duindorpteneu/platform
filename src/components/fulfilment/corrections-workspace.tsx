"use client";

import { AlertTriangle, CheckCircle2, History, Loader2, PackageCheck, Undo2 } from "lucide-react";
import { useRouter } from "next/navigation";
import { useState } from "react";
import type { FulfilmentCorrectionsWorkspace as Workspace } from "@/lib/fulfilment-corrections-contract";

function moment(value: string) {
  return new Intl.DateTimeFormat("nl-NL", { dateStyle: "medium", timeStyle: "short", timeZone: "Europe/Amsterdam" }).format(new Date(value));
}

export function CorrectionsWorkspace({ workspace }: { workspace: Workspace }) {
  const router = useRouter();
  const [selected, setSelected] = useState<string[]>([]);
  const [targetStatus, setTargetStatus] = useState<"ready_for_pickup" | "backorder">("ready_for_pickup");
  const [reason, setReason] = useState("");
  const [requestId, setRequestId] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<{ tone: "success" | "error"; text: string } | null>(null);
  async function correct() {
    const stableRequestId = requestId ?? crypto.randomUUID();
    setRequestId(stableRequestId);
    setBusy(true); setMessage(null);
    try {
      const response = await fetch("/api/fulfilment/reverse", { method: "POST", headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" }, body: JSON.stringify({ orderLineIds: selected, targetStatus, reason, requestId: stableRequestId }) });
      const payload = await response.json() as { correctedLines?: number; error?: string };
      if (!response.ok) throw new Error(payload.error ?? "Correctie mislukt.");
      setSelected([]); setReason(""); setRequestId(null);
      setMessage({ tone: "success", text: `${payload.correctedLines ?? 0} regel(s) transactioneel gecorrigeerd.` });
      router.refresh();
    } catch (error) {
      setMessage({ tone: "error", text: error instanceof Error ? error.message : "Correctie mislukt." });
    } finally { setBusy(false); }
  }
  return <div className="mx-auto max-w-[1280px]">
    <div><p className="text-xs font-semibold uppercase tracking-[0.12em] text-brand-500">Backoffice · historie</p><h1 className="mt-2 text-[30px] font-bold tracking-[-0.04em] text-brand-900">Uitgiftes en correcties</h1><p className="mt-2 text-sm text-slate-500">Corrigeer uitsluitend foutief uitgegeven regels. De oorspronkelijke uitgifte blijft volledig in de historie staan.</p></div>
    {message && <div role="status" className={`mt-6 flex gap-3 rounded-xl border p-4 text-sm ${message.tone === "success" ? "border-emerald-100 bg-emerald-50 text-success" : "border-red-100 bg-red-50 text-danger"}`}>{message.tone === "success" ? <CheckCircle2 className="size-5 shrink-0" /> : <AlertTriangle className="size-5 shrink-0" />}{message.text}</div>}
    <div className="mt-8 grid items-start gap-6 xl:grid-cols-[minmax(0,1fr)_360px]">
      <section className="overflow-hidden rounded-xl border border-line bg-white shadow-card">
        <div className="flex items-center justify-between border-b border-line px-5 py-4"><div><h2 className="text-base font-bold text-brand-900">Recente uitgiftes</h2><p className="mt-1 text-xs text-slate-500">Maximaal 100 registraties, nieuwste eerst</p></div><History className="size-5 text-brand-500" /></div>
        {workspace.fulfilments.length === 0 ? <div className="px-6 py-20 text-center"><PackageCheck className="mx-auto size-9 text-slate-300" /><p className="mt-4 text-sm font-semibold text-slate-600">Nog geen uitgiftes geregistreerd</p><p className="mt-1 text-xs text-slate-400">Na een eerste balie-uitgifte verschijnt de onveranderlijke historie hier.</p></div> : <div className="divide-y divide-line">{workspace.fulfilments.map((fulfilment) => <article key={fulfilment.id} className="p-5">
          <div className="flex flex-col justify-between gap-2 sm:flex-row"><div><h3 className="text-sm font-bold text-brand-900">{fulfilment.memberName}</h3><p className="mt-1 text-[11px] text-slate-500">{fulfilment.team} · {fulfilment.relationNumber ?? "Geen relatienummer"} · {fulfilment.location}</p></div><time className="text-[11px] font-semibold text-slate-400">{moment(fulfilment.fulfilledAt)}</time></div>
          <div className="mt-4 grid gap-2 sm:grid-cols-2">{fulfilment.lines.map((line) => {
            const selectable = line.reversedAt === null && line.status === "picked_up";
            const checked = selected.includes(line.orderLineId);
            return <label key={line.id} className={`flex min-h-14 items-center gap-3 rounded-lg border px-3 py-2.5 ${selectable ? "cursor-pointer border-line hover:border-brand-500" : "border-transparent bg-slate-50"}`}><input type="checkbox" disabled={!selectable} checked={checked} onChange={() => { setRequestId(null); setSelected((current) => checked ? current.filter((id) => id !== line.orderLineId) : [...current, line.orderLineId]); }} className="size-4 rounded border-slate-300 text-brand-700 focus:ring-brand-500 disabled:hidden" /><span className="min-w-0 flex-1"><span className="block truncate text-xs font-semibold text-ink">{line.article} · {line.size}</span><span className="mt-1 block text-[10px] text-slate-400">{line.quantity} stuk{line.quantity === 1 ? "" : "s"}{line.reversedAt ? ` · Gecorrigeerd ${moment(line.reversedAt)}` : " · Uitgegeven"}</span>{line.reversalReason && <span className="mt-1 block text-[10px] text-slate-500">Reden: {line.reversalReason}</span>}</span>{line.reversedAt && <Undo2 className="size-4 shrink-0 text-warning" />}</label>;
          })}</div>
        </article>)}</div>}
      </section>
      <aside className="sticky top-[106px] rounded-xl border border-line bg-white p-5 shadow-card">
        <p className="text-[10px] font-bold uppercase tracking-[0.12em] text-brand-500">Gecontroleerde reversal</p><h2 className="mt-2 text-base font-bold text-brand-900">Selectie corrigeren</h2><p className="mt-1 text-xs leading-5 text-slate-500">{selected.length} regel(s) geselecteerd. Uitgiftemedewerkers hebben geen toegang tot deze actie.</p>
        <label htmlFor="history-target" className="mt-5 block text-xs font-semibold text-ink">Doelstatus</label><select id="history-target" value={targetStatus} onChange={(event) => { setRequestId(null); setTargetStatus(event.target.value as typeof targetStatus); }} className="mt-2 h-11 w-full rounded-lg border border-line bg-white px-3 text-xs outline-none focus:border-brand-500"><option value="ready_for_pickup">Af te halen — reservering behouden</option><option value="backorder">Nalevering — voorraad vrijgeven</option></select>
        <label htmlFor="history-reason" className="mt-4 block text-xs font-semibold text-ink">Verplichte reden</label><textarea id="history-reason" value={reason} onChange={(event) => { setRequestId(null); setReason(event.target.value); }} maxLength={500} rows={4} placeholder="Beschrijf de administratieve fout…" className="mt-2 w-full rounded-lg border border-line px-3 py-2 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" />
        <button type="button" onClick={() => void correct()} disabled={busy || selected.length === 0 || reason.trim().length < 4} className="mt-4 inline-flex h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-sm font-semibold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:bg-slate-300">{busy ? <Loader2 className="size-4 animate-spin" /> : <Undo2 className="size-4" />} Correctie bevestigen</button>
      </aside>
    </div>
  </div>;
}
