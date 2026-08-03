"use client";

import { AlertTriangle, CheckCircle2, Loader2, RefreshCw, ShieldCheck } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";

type Season = { id: string; name: string };
type Candidate = {
  id: string;
  receiptLineId: string;
  variantId: string;
  productName: string;
  size: string;
  reviewSeasonId: string;
  legacyReceived: number;
  legacyReserved: number;
  legacyIssued: number;
  unassignedQuantity: number;
  assignedQuantity: number;
  remainingQuantity: number;
  status: string;
  sourceHash: string;
};
type ReviewAllocation = {
  id: string;
  seasonId: string;
  orderId: string;
  orderLineId: string;
  variantId: string;
  productName: string;
  size: string;
  quantity: number;
  status: "reserved" | "fulfilled";
  paidAt: string | null;
  sizeValidAt: string | null;
  allocatedAt: string;
};
type Workspace = {
  report: {
    pendingCandidates: number;
    pendingQuantity: number;
    discrepancyCandidates: number;
    reviewAllocations: number;
    ready: boolean;
    hash: string;
  };
  candidates: Candidate[];
  reviewAllocations: ReviewAllocation[];
};

export function InventoryReconciliationPanel({
  seasons,
  blockerCount,
  onChanged,
}: {
  seasons: Season[];
  blockerCount: number;
  onChanged: () => Promise<void>;
}) {
  const [workspace, setWorkspace] = useState<Workspace | null>(null);
  const [loading, setLoading] = useState(false);
  const [savingId, setSavingId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [seasonByCandidate, setSeasonByCandidate] = useState<Record<string, string>>({});
  const [quantityByCandidate, setQuantityByCandidate] = useState<Record<string, string>>({});
  const [reasonByObject, setReasonByObject] = useState<Record<string, string>>({});
  const requestIds = useRef<Record<string, string>>({});

  const load = useCallback(async () => {
    if (blockerCount === 0) return;
    setLoading(true);
    setError(null);
    try {
      const response = await fetch("/api/stock/reconciliation", { cache: "no-store" });
      const payload = await response.json() as Workspace & { error?: string };
      if (!response.ok) throw new Error(payload.error ?? "Reconciliatie kon niet worden geladen.");
      setWorkspace(payload);
      setSeasonByCandidate((current) => ({
        ...Object.fromEntries(payload.candidates.map((candidate) => [candidate.id, candidate.reviewSeasonId])),
        ...current,
      }));
      setQuantityByCandidate((current) => ({
        ...Object.fromEntries(payload.candidates.map((candidate) => [candidate.id, String(candidate.remainingQuantity)])),
        ...current,
      }));
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : "Reconciliatie kon niet worden geladen.");
    } finally {
      setLoading(false);
    }
  }, [blockerCount]);

  useEffect(() => { void load(); }, [load]);

  function stableRequestId(key: string) {
    requestIds.current[key] ??= crypto.randomUUID();
    return requestIds.current[key];
  }

  async function assign(candidate: Candidate) {
    const reason = reasonByObject[candidate.id]?.trim() ?? "";
    const quantity = Number(quantityByCandidate[candidate.id]);
    const seasonId = seasonByCandidate[candidate.id];
    setSavingId(candidate.id);
    setError(null);
    setSuccess(null);
    try {
      const response = await fetch("/api/stock/reconciliation", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" },
        body: JSON.stringify({
          reconciliationId: candidate.id,
          seasonId,
          quantity,
          reason,
          requestId: stableRequestId(`assign:${candidate.id}`),
        }),
      });
      const payload = await response.json() as { remainingQuantity?: number; error?: string };
      if (!response.ok) throw new Error(payload.error ?? "Openingsvoorraad kon niet worden toegewezen.");
      delete requestIds.current[`assign:${candidate.id}`];
      setSuccess(`Toewijzing opgeslagen; ${payload.remainingQuantity ?? 0} stuks blijven te reconciliëren.`);
      await load();
      await onChanged();
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : "Openingsvoorraad kon niet worden toegewezen.");
    } finally {
      setSavingId(null);
    }
  }

  async function resolve(allocation: ReviewAllocation) {
    const reason = reasonByObject[allocation.id]?.trim() ?? "";
    const decision = allocation.status === "reserved" ? "release_requeue" : "accept_historical";
    setSavingId(allocation.id);
    setError(null);
    setSuccess(null);
    try {
      const response = await fetch("/api/stock/reconciliation", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" },
        body: JSON.stringify({
          allocationId: allocation.id,
          decision,
          reason,
          requestId: stableRequestId(`allocation:${allocation.id}`),
        }),
      });
      const payload = await response.json() as { error?: string };
      if (!response.ok) throw new Error(payload.error ?? "Legacyallocatie kon niet worden gereconcilieerd.");
      delete requestIds.current[`allocation:${allocation.id}`];
      setSuccess(decision === "release_requeue"
        ? "Onbewezen reservering is vrijgegeven en opnieuw voor veilige FIFO aangeboden."
        : "Historische uitgifte is met expliciete beheerreden geaccepteerd.");
      await load();
      await onChanged();
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : "Legacyallocatie kon niet worden gereconcilieerd.");
    } finally {
      setSavingId(null);
    }
  }

  if (blockerCount === 0) {
    return <section className="mt-6 flex items-start gap-3 rounded-2xl border border-emerald-200 bg-emerald-50 p-5 text-xs text-emerald-900"><ShieldCheck className="mt-0.5 size-5 shrink-0" /><div><h2 className="font-bold">Legacyvoorraad gereconcilieerd</h2><p className="mt-1">Er zijn geen onbewezen vrije stuks of reviewallocaties in de beheerqueue.</p></div></section>;
  }

  return (
    <section className="mt-6 rounded-2xl border border-red-200 bg-white shadow-card">
      <div className="flex flex-wrap items-start justify-between gap-3 border-b border-red-100 bg-red-50 p-5">
        <div><p className="text-[10px] font-bold uppercase tracking-[0.1em] text-red-500">Alleen beheerder · AAL2</p><h2 className="mt-1 text-base font-bold text-red-900">Productieblokkades reconciliëren</h2><p className="mt-1 text-xs text-red-700">Geen seizoen of bedrijfsfeit wordt gegokt. Iedere oplossing vraagt een expliciete reden en blijft auditbaar.</p></div>
        <button onClick={() => void load()} disabled={loading} className="inline-flex h-9 items-center gap-2 rounded-lg border border-red-200 bg-white px-3 text-xs font-semibold text-red-800 disabled:opacity-60"><RefreshCw className={`size-3.5 ${loading ? "animate-spin" : ""}`} /> Vernieuwen</button>
      </div>
      {(error || success) && <div role={error ? "alert" : "status"} className={`m-5 flex items-start gap-2 rounded-xl border p-3 text-xs ${error ? "border-red-100 bg-red-50 text-danger" : "border-emerald-100 bg-emerald-50 text-success"}`}>{error ? <AlertTriangle className="size-4 shrink-0" /> : <CheckCircle2 className="size-4 shrink-0" />}{error ?? success}</div>}
      {!workspace ? <div className="p-8 text-center text-xs text-slate-400">{loading ? "Reconciliatie laden…" : "Reconciliatie is niet beschikbaar."}</div> : <div className="grid gap-6 p-5 lg:grid-cols-2">
        <div>
          <h3 className="text-xs font-bold uppercase tracking-[0.08em] text-slate-500">Vrije legacyvoorraad zonder seizoen</h3>
          <div className="mt-3 space-y-3">{workspace.candidates.length === 0 ? <p className="rounded-xl border border-dashed border-line p-4 text-center text-xs text-slate-400">Geen open ontvangstregels.</p> : workspace.candidates.map((candidate) => <div key={candidate.id} className="rounded-xl border border-line p-4"><div className="flex items-start justify-between gap-3"><div><p className="text-xs font-bold text-ink">{candidate.productName} · {candidate.size}</p><p className="mt-1 text-[10px] text-slate-400">Ontvangen {candidate.legacyReceived} · gereserveerd {candidate.legacyReserved} · uitgegeven {candidate.legacyIssued}</p></div><span className="rounded-full bg-red-50 px-2 py-1 text-[9px] font-bold text-danger">{candidate.remainingQuantity} open</span></div><div className="mt-3 grid gap-2 sm:grid-cols-2"><label className="text-[10px] font-semibold text-slate-600">Seizoen<select value={seasonByCandidate[candidate.id] ?? ""} onChange={(event) => setSeasonByCandidate((current) => ({ ...current, [candidate.id]: event.target.value }))} className="mt-1 h-9 w-full rounded-lg border border-line bg-white px-2 text-xs">{seasons.map((season) => <option key={season.id} value={season.id}>{season.name}</option>)}</select></label><label className="text-[10px] font-semibold text-slate-600">Aantal<input type="number" min={1} max={candidate.remainingQuantity} value={quantityByCandidate[candidate.id] ?? ""} onChange={(event) => setQuantityByCandidate((current) => ({ ...current, [candidate.id]: event.target.value }))} className="mt-1 h-9 w-full rounded-lg border border-line px-2 text-xs" /></label></div><label className="mt-2 block text-[10px] font-semibold text-slate-600">Bewijs/reden<input value={reasonByObject[candidate.id] ?? ""} onChange={(event) => setReasonByObject((current) => ({ ...current, [candidate.id]: event.target.value }))} maxLength={500} placeholder="Waarom hoort dit aantal bij dit seizoen?" className="mt-1 h-9 w-full rounded-lg border border-line px-2 text-xs" /></label><button onClick={() => void assign(candidate)} disabled={savingId === candidate.id || !seasonByCandidate[candidate.id] || (reasonByObject[candidate.id]?.trim().length ?? 0) < 4} className="mt-3 flex h-9 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 text-xs font-semibold text-white disabled:bg-slate-300">{savingId === candidate.id ? <Loader2 className="size-3.5 animate-spin" /> : <ShieldCheck className="size-3.5" />} Gecontroleerd toewijzen</button></div>)}</div>
        </div>
        <div>
          <h3 className="text-xs font-bold uppercase tracking-[0.08em] text-slate-500">Onbewezen legacyallocaties</h3>
          <div className="mt-3 space-y-3">{workspace.reviewAllocations.length === 0 ? <p className="rounded-xl border border-dashed border-line p-4 text-center text-xs text-slate-400">Geen reviewallocaties.</p> : workspace.reviewAllocations.map((allocation) => <div key={allocation.id} className="rounded-xl border border-line p-4"><div className="flex items-start justify-between gap-3"><div><p className="text-xs font-bold text-ink">{allocation.productName} · {allocation.size}</p><p className="mt-1 text-[10px] text-slate-400">{allocation.quantity} stuk · {allocation.paidAt ? "betaling bekend" : "geen definitieve betaling"} · {allocation.sizeValidAt ? "maat geldig" : "maat niet bewezen"}</p></div><span className="rounded-full bg-amber-50 px-2 py-1 text-[9px] font-bold text-warning">{allocation.status === "reserved" ? "Reservering" : "Historisch uitgegeven"}</span></div><p className="mt-3 rounded-lg bg-slate-50 p-2 text-[10px] text-slate-600">{allocation.status === "reserved" ? "Veilige keuze: vrijgeven en opnieuw door betaald+maatgeldig FIFO laten beoordelen." : "Uitgiftehistorie wordt nooit teruggedraaid; beheer accepteert het historische feit alleen met bewijsreden."}</p><label className="mt-2 block text-[10px] font-semibold text-slate-600">Besluitreden<input value={reasonByObject[allocation.id] ?? ""} onChange={(event) => setReasonByObject((current) => ({ ...current, [allocation.id]: event.target.value }))} maxLength={500} className="mt-1 h-9 w-full rounded-lg border border-line px-2 text-xs" /></label><button onClick={() => void resolve(allocation)} disabled={savingId === allocation.id || (reasonByObject[allocation.id]?.trim().length ?? 0) < 4} className="mt-3 flex h-9 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 text-xs font-semibold text-white disabled:bg-slate-300">{savingId === allocation.id ? <Loader2 className="size-3.5 animate-spin" /> : <ShieldCheck className="size-3.5" />} {allocation.status === "reserved" ? "Vrijgeven en herplannen" : "Historisch feit accepteren"}</button></div>)}</div>
        </div>
      </div>}
    </section>
  );
}
