"use client";

import {
  AlertTriangle,
  Boxes,
  Check,
  CheckCircle2,
  ClipboardCheck,
  Loader2,
  Package,
  Plus,
  RefreshCw,
  ShieldAlert,
  Users,
  X,
} from "lucide-react";
import { FormEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { DeliveryNotificationProposalPanel } from "@/components/stock/delivery-notification-proposal";
import { InventoryReconciliationPanel } from "@/components/stock/inventory-reconciliation-panel";
import { InventoryThresholdControl } from "@/components/stock/inventory-threshold-control";

type Season = { id: string; name: string; status: string };
type Product = { id: string; name: string; code: string; variantCount: number };
type Variant = {
  id: string;
  articleId: string;
  article: string;
  size: string;
  sku: string | null;
  onHand: number;
  reserved: number;
  issued: number;
  available: number;
  totalOpenDemand: number;
  paidWaiting: number;
  unpaidDemand: number;
  unconfirmedDemand: number;
  pickedUp: number;
  shortage: number;
};
type DraftLine = {
  id: string;
  articleId: string;
  variantId: string;
  productName: string;
  productCode: string;
  size: string;
  sku: string | null;
  quantity: number | null;
  confirmed: boolean;
  confirmedAt: string | null;
};
type Draft = {
  id: string;
  seasonId: string;
  status: "draft" | "ready" | "posted";
  receivedOn: string;
  supplier: string;
  packingSlipReference: string | null;
  revision: number;
  postedReceiptId: string | null;
  postedAt: string | null;
  createdAt: string;
  updatedAt: string;
  lineCount: number;
  confirmedCount: number;
  totalQuantity: number;
  lines: DraftLine[];
};
type WaitlistLine = {
  orderLineId: string;
  orderId: string;
  memberName: string;
  relationNumber: string | null;
  team: string | null;
  variantId: string;
  quantity: number;
  paid: boolean;
  sizeValid: boolean;
  fifoAt: string | null;
  eligible: boolean;
  createdAt: string;
};
type Overview = {
  seasonId: string;
  enabled: boolean;
  role: "beheerder" | "kledingcommissie";
  lowStockThreshold: number;
  seasons: Season[];
  products: Product[];
  variants: Variant[];
  drafts: Draft[];
  waitlist: WaitlistLine[];
  reconciliation: { pendingCandidates: number; reviewAllocations: number };
};
type LineEdit = { quantity: string; confirmed: boolean };
type ApiError = { error?: string };

const emptyOverview: Overview = {
  seasonId: "",
  enabled: false,
  role: "kledingcommissie",
  lowStockThreshold: 10,
  seasons: [],
  products: [],
  variants: [],
  drafts: [],
  waitlist: [],
  reconciliation: { pendingCandidates: 0, reviewAllocations: 0 },
};

function newRequestId() {
  return crypto.randomUUID();
}

function formatDate(value: string) {
  return new Intl.DateTimeFormat("nl-NL", { dateStyle: "medium" }).format(new Date(value));
}

export function DeliveriesWorkspace() {
  const [overview, setOverview] = useState<Overview>(emptyOverview);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [receivedOn, setReceivedOn] = useState(() => new Date().toISOString().slice(0, 10));
  const [supplier, setSupplier] = useState("");
  const [packingSlip, setPackingSlip] = useState("");
  const [selectedProducts, setSelectedProducts] = useState<string[]>([]);
  const [selectedDraftId, setSelectedDraftId] = useState<string | null>(null);
  const [lineEdits, setLineEdits] = useState<Record<string, LineEdit>>({});
  const createRequestId = useRef<string>(newRequestId());
  const saveRequestId = useRef<string>(newRequestId());
  const postRequestId = useRef<string>(newRequestId());

  const load = useCallback(async (seasonId?: string, preferredDraftId?: string | null) => {
    setLoading(true);
    setError(null);
    try {
      const query = seasonId ? `?seasonId=${encodeURIComponent(seasonId)}` : "";
      const response = await fetch(`/api/stock/overview${query}`, { cache: "no-store" });
      const payload = await response.json() as Overview & ApiError;
      if (!response.ok) throw new Error(payload.error ?? "Het voorraadoverzicht kon niet worden geladen.");
      setOverview(payload);
      const nextDraft = preferredDraftId
        ? payload.drafts.find((draft) => draft.id === preferredDraftId)
        : payload.drafts.find((draft) => draft.status !== "posted");
      setSelectedDraftId((current) => (
        nextDraft?.id
        ?? (payload.drafts.some((draft) => draft.id === current) ? current : null)
      ));
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : "Het voorraadoverzicht kon niet worden geladen.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  const selectedDraft = overview.drafts.find((draft) => draft.id === selectedDraftId) ?? null;
  useEffect(() => {
    if (!selectedDraft) {
      setLineEdits({});
      return;
    }
    setLineEdits(Object.fromEntries(selectedDraft.lines.map((line) => [
      line.variantId,
      { quantity: line.quantity === null ? "" : String(line.quantity), confirmed: line.confirmed },
    ])));
    saveRequestId.current = newRequestId();
    postRequestId.current = newRequestId();
  }, [selectedDraft]);

  async function createDraft(event: FormEvent) {
    event.preventDefault();
    setSaving(true);
    setError(null);
    setSuccess(null);
    try {
      const response = await fetch("/api/stock/drafts", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" },
        body: JSON.stringify({
          seasonId: overview.seasonId,
          receivedOn,
          supplier,
          packingSlipReference: packingSlip.trim() || undefined,
          articleIds: selectedProducts,
          requestId: createRequestId.current,
        }),
      });
      const payload = await response.json() as Draft & ApiError;
      if (!response.ok) throw new Error(payload.error ?? "Het leveringconcept kon niet worden gemaakt.");
      createRequestId.current = newRequestId();
      setSupplier("");
      setPackingSlip("");
      setSelectedProducts([]);
      setSuccess(`${payload.lineCount} maatregels zijn als concept klaargezet.`);
      await load(overview.seasonId, payload.id);
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : "Het leveringconcept kon niet worden gemaakt.");
    } finally {
      setSaving(false);
    }
  }

  async function saveDraft() {
    if (!selectedDraft) return;
    setSaving(true);
    setError(null);
    setSuccess(null);
    try {
      const lines = selectedDraft.lines.map((line) => {
        const edit = lineEdits[line.variantId] ?? { quantity: "", confirmed: false };
        return {
          variantId: line.variantId,
          quantity: edit.quantity === "" ? null : Number(edit.quantity),
          confirmed: edit.confirmed,
        };
      });
      const response = await fetch(`/api/stock/drafts/${selectedDraft.id}`, {
        method: "PUT",
        headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" },
        body: JSON.stringify({
          expectedRevision: selectedDraft.revision,
          requestId: saveRequestId.current,
          lines,
        }),
      });
      const payload = await response.json() as Draft & ApiError;
      if (!response.ok) throw new Error(payload.error ?? "Het leveringconcept kon niet worden opgeslagen.");
      saveRequestId.current = newRequestId();
      setSuccess(payload.status === "ready"
        ? "Alle maatregels zijn bevestigd. De totale levering kan nu worden geboekt."
        : "Concept opgeslagen; bevestig iedere maatregel afzonderlijk.");
      await load(overview.seasonId, selectedDraft.id);
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : "Het leveringconcept kon niet worden opgeslagen.");
    } finally {
      setSaving(false);
    }
  }

  async function postDraft() {
    if (!selectedDraft || selectedDraft.status !== "ready") return;
    if (!window.confirm(`Boek de totale levering van ${selectedDraft.totalQuantity} stuks atomair?`)) return;
    setSaving(true);
    setError(null);
    setSuccess(null);
    try {
      const response = await fetch(`/api/stock/drafts/${selectedDraft.id}/post`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" },
        body: JSON.stringify({
          expectedRevision: selectedDraft.revision,
          requestId: postRequestId.current,
        }),
      });
      const payload = await response.json() as { allocatedLines?: number } & ApiError;
      if (!response.ok) throw new Error(payload.error ?? "De levering kon niet worden geboekt.");
      postRequestId.current = newRequestId();
      setSuccess(`Levering geboekt. ${payload.allocatedLines ?? 0} betaalde, maatgeldige regels kregen volgens FIFO voorraad.`);
      await load(overview.seasonId, selectedDraft.id);
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : "De levering kon niet worden geboekt.");
    } finally {
      setSaving(false);
    }
  }

  const totals = useMemo(() => overview.variants.reduce(
    (result, item) => ({
      onHand: result.onHand + item.onHand,
      reserved: result.reserved + item.reserved,
      available: result.available + item.available,
      paidWaiting: result.paidWaiting + item.paidWaiting,
    }),
    { onHand: 0, reserved: 0, available: 0, paidWaiting: 0 },
  ), [overview.variants]);
  const groupedLines = useMemo(() => {
    if (!selectedDraft) return [];
    const groups = new Map<string, DraftLine[]>();
    selectedDraft.lines.forEach((line) => groups.set(line.productName, [...(groups.get(line.productName) ?? []), line]));
    return [...groups.entries()];
  }, [selectedDraft]);
  const blockers = overview.reconciliation.pendingCandidates + overview.reconciliation.reviewAllocations;

  if (loading && overview.seasons.length === 0) {
    return <div className="mx-auto max-w-[1240px] animate-pulse"><div className="h-9 w-64 rounded bg-slate-200" /><div className="mt-8 grid gap-5 md:grid-cols-4">{Array.from({ length: 4 }, (_, index) => <div key={index} className="h-28 rounded-2xl bg-white" />)}</div></div>;
  }

  return (
    <div className="mx-auto max-w-[1240px]">
      <div className="flex flex-col justify-between gap-4 md:flex-row md:items-end">
        <div>
          <p className="text-xs font-bold uppercase tracking-[0.14em] text-brand-500">Journaal en FIFO</p>
          <h1 className="mt-2 text-3xl font-bold tracking-tight text-brand-900">Leveringen</h1>
          <p className="mt-2 max-w-2xl text-sm text-slate-500">Een concept wijzigt niets. Pas na bevestiging van iedere maatregel wordt de totale levering atomair geboekt en uitsluitend aan betaalde, maatgeldige regels toegewezen.</p>
        </div>
        <div className="flex gap-2">
          <label className="sr-only" htmlFor="inventory-season">Seizoen</label>
          <select id="inventory-season" value={overview.seasonId} onChange={(event) => void load(event.target.value)} className="h-10 rounded-lg border border-line bg-white px-3 text-xs font-semibold text-slate-600 outline-none focus:border-brand-500">
            {overview.seasons.map((season) => <option key={season.id} value={season.id}>{season.name}</option>)}
          </select>
          <button onClick={() => void load(overview.seasonId, selectedDraftId)} disabled={loading} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-line bg-white px-3.5 text-xs font-semibold text-slate-600 hover:border-brand-500 disabled:opacity-60"><RefreshCw className={`size-3.5 ${loading ? "animate-spin" : ""}`} /> Vernieuwen</button>
        </div>
      </div>

      {!overview.enabled && <div role="status" className="mt-5 flex items-start gap-3 rounded-xl border border-amber-200 bg-amber-50 p-4 text-xs text-amber-900"><ShieldAlert className="mt-0.5 size-4 shrink-0" /><div><p className="font-bold">Gecontroleerde cutover nog gesloten</p><p className="mt-1">Concepten kunnen worden voorbereid. Definitief boeken blijft geblokkeerd tot legacyvoorraad en scannerketen volledig zijn gereconcilieerd.</p></div></div>}
      {blockers > 0 && <div role="alert" className="mt-4 flex items-start gap-3 rounded-xl border border-red-200 bg-red-50 p-4 text-xs text-red-800"><AlertTriangle className="mt-0.5 size-4 shrink-0" /><div><p className="font-bold">{blockers} productieblokkade{blockers === 1 ? "" : "s"} in legacyvoorraad</p><p className="mt-1">{overview.reconciliation.pendingCandidates} vrije ontvangstregels missen een bewezen seizoen; {overview.reconciliation.reviewAllocations} allocaties vragen beheercontrole.</p></div></div>}
      {(error || success) && <div role={error ? "alert" : "status"} className={`mt-4 flex items-start gap-2 rounded-xl border p-4 text-xs ${error ? "border-red-100 bg-red-50 text-danger" : "border-emerald-100 bg-emerald-50 text-success"}`}>{error ? <AlertTriangle className="size-4 shrink-0" /> : <CheckCircle2 className="size-4 shrink-0" />}{error ?? success}</div>}

      <div className="mt-6 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        {[
          { label: "Fysiek", value: totals.onHand, detail: "actueel aanwezig", icon: Package },
          { label: "Gereserveerd", value: totals.reserved, detail: "hard voor betaald", icon: ClipboardCheck },
          { label: "Vrij", value: totals.available, detail: "fysiek min reservering", icon: CheckCircle2 },
          { label: "Betaald wachtend", value: totals.paidWaiting, detail: "maatgeldig zonder allocatie", icon: Users },
        ].map((item) => {
          const Icon = item.icon;
          return <div key={item.label} className="rounded-2xl border border-line bg-white p-5 shadow-card"><div className="flex items-center justify-between"><p className="text-xs font-semibold text-slate-500">{item.label}</p><Icon className="size-4 text-brand-500" /></div><p className="mt-3 text-2xl font-bold text-brand-900">{item.value}</p><p className="mt-1 text-xs text-slate-500">{item.detail}</p></div>;
        })}
      </div>

      <div className="mt-6 grid gap-6 xl:grid-cols-[390px_1fr]">
        <div className="space-y-5">
          <form onSubmit={(event) => void createDraft(event)} className="rounded-2xl border border-line bg-white p-6 shadow-card">
            <div className="flex items-center gap-3"><div className="flex size-10 items-center justify-center rounded-xl bg-brand-50 text-brand-700"><Plus className="size-4" /></div><div><p className="text-xs font-bold uppercase tracking-[0.12em] text-slate-500">Stap 1</p><h2 className="mt-1 text-base font-bold text-brand-900">Leveringconcept starten</h2></div></div>
            <div className="mt-6 grid gap-4">
              <label className="text-xs font-semibold text-ink">Ontvangstdatum<input type="date" value={receivedOn} onChange={(event) => setReceivedOn(event.target.value)} required className="mt-2 h-11 w-full rounded-lg border border-line px-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></label>
              <label className="text-xs font-semibold text-ink">Leverancier<input value={supplier} onChange={(event) => setSupplier(event.target.value)} required maxLength={160} placeholder="Naam leverancier" className="mt-2 h-11 w-full rounded-lg border border-line px-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></label>
              <label className="text-xs font-semibold text-ink">Pakbonreferentie<input value={packingSlip} onChange={(event) => setPackingSlip(event.target.value)} maxLength={160} placeholder="Optioneel" className="mt-2 h-11 w-full rounded-lg border border-line px-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></label>
              <fieldset><legend className="text-xs font-semibold text-ink">Producten in deze levering</legend><div className="mt-2 max-h-48 space-y-2 overflow-y-auto rounded-xl border border-line p-3">{overview.products.length === 0 ? <p className="py-3 text-center text-xs text-slate-500">Voeg eerst producten en maten toe.</p> : overview.products.map((product) => { const checked = selectedProducts.includes(product.id); return <label key={product.id} className="flex min-h-10 cursor-pointer items-center gap-3 rounded-lg px-2 hover:bg-slate-50"><input type="checkbox" checked={checked} onChange={() => setSelectedProducts((current) => checked ? current.filter((id) => id !== product.id) : [...current, product.id])} className="size-4 rounded border-slate-300 text-brand-700 focus:ring-brand-500" /><span className="min-w-0 flex-1 text-xs font-semibold text-ink">{product.name}</span><span className="text-xs text-slate-500">{product.variantCount} maten</span></label>; })}</div></fieldset>
            </div>
            <button disabled={saving || selectedProducts.length === 0 || !supplier.trim()} className="mt-6 flex h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 text-sm font-semibold text-white hover:bg-brand-900 disabled:bg-slate-300">{saving ? <Loader2 className="size-4 animate-spin" /> : <Boxes className="size-4" />} Maatmatrix genereren</button>
          </form>

          <section className="rounded-2xl border border-line bg-white p-5 shadow-card">
            <h2 className="text-sm font-bold text-brand-900">Leveringconcepten</h2>
            <div className="mt-4 space-y-2">{overview.drafts.length === 0 ? <p className="rounded-lg border border-dashed border-line p-4 text-center text-xs text-slate-500">Nog geen concepten</p> : overview.drafts.map((draft) => <button key={draft.id} onClick={() => setSelectedDraftId(draft.id)} className={`w-full rounded-xl border p-3 text-left transition-colors ${selectedDraftId === draft.id ? "border-brand-500 bg-brand-50" : "border-line hover:border-brand-300"}`}><span className="flex items-center justify-between gap-2"><span className="truncate text-xs font-bold text-ink">{draft.supplier}</span><span className={`rounded-full px-2 py-0.5 text-xs font-bold ${draft.status === "ready" ? "bg-emerald-50 text-success" : draft.status === "posted" ? "bg-slate-100 text-slate-500" : "bg-amber-50 text-warning"}`}>{draft.status === "ready" ? "Compleet" : draft.status === "posted" ? "Geboekt" : "Concept"}</span></span><span className="mt-1 block text-xs text-slate-500">{formatDate(draft.receivedOn)} · {draft.confirmedCount}/{draft.lineCount} bevestigd</span></button>)}</div>
          </section>
        </div>

        <section className="overflow-hidden rounded-2xl border border-line bg-white shadow-card">
          {!selectedDraft ? <div className="flex min-h-[460px] flex-col items-center justify-center p-8 text-center"><ClipboardCheck className="size-8 text-slate-300" /><h2 className="mt-4 text-base font-bold text-brand-900">Selecteer of start een concept</h2><p className="mt-2 max-w-sm text-xs text-slate-500">Daarna verschijnt voor ieder gekozen product de volledige actieve maattabel.</p></div> : <>
            <div className="border-b border-line p-6"><div className="flex flex-wrap items-start justify-between gap-3"><div><p className="text-xs font-bold uppercase tracking-[0.12em] text-slate-500">Stap 2 · volledige maatmatrix</p><h2 className="mt-1 text-lg font-bold text-brand-900">{selectedDraft.supplier}</h2><p className="mt-1 text-xs text-slate-500">{selectedDraft.packingSlipReference ?? "Geen pakbonreferentie"} · revisie {selectedDraft.revision}</p></div><span className="rounded-full bg-slate-100 px-3 py-1 text-xs font-bold text-slate-600">{selectedDraft.confirmedCount}/{selectedDraft.lineCount} bevestigd</span></div></div>
            <div className="max-h-[640px] overflow-y-auto p-6">
              <div className="space-y-6">{groupedLines.map(([productName, lines]) => <fieldset key={productName}><legend className="mb-2 text-xs font-bold uppercase tracking-[0.08em] text-brand-900">{productName}</legend><div className="overflow-hidden rounded-xl border border-line"><div className="grid grid-cols-[1fr_120px_120px] bg-slate-50 px-4 py-2 text-xs font-bold uppercase tracking-[0.08em] text-slate-500"><span>Maat</span><span>Aantal</span><span>Bevestigd</span></div><div className="divide-y divide-line">{lines.map((line) => { const edit = lineEdits[line.variantId] ?? { quantity: "", confirmed: false }; const zero = edit.quantity === "0"; return <div key={line.id} className="grid min-h-14 grid-cols-[1fr_120px_120px] items-center px-4 py-2"><div><p className="text-xs font-semibold text-ink">{line.size}</p><p className="mt-0.5 text-xs text-slate-500">{line.sku ?? "Geen SKU"}</p></div><input aria-label={`Aantal ${productName} maat ${line.size}`} type="number" min={0} max={10000} value={edit.quantity} disabled={selectedDraft.status === "posted"} onChange={(event) => setLineEdits((current) => ({ ...current, [line.variantId]: { ...edit, quantity: event.target.value, confirmed: false } }))} className={`h-9 w-24 rounded-lg border px-2 text-xs outline-none focus:border-brand-500 ${zero ? "border-amber-200 bg-amber-50 text-amber-900" : "border-line"}`} placeholder="—" /><label className="inline-flex min-h-9 cursor-pointer items-center gap-2 text-xs font-semibold text-slate-600"><input type="checkbox" disabled={selectedDraft.status === "posted" || edit.quantity === ""} checked={edit.confirmed} onChange={(event) => setLineEdits((current) => ({ ...current, [line.variantId]: { ...edit, confirmed: event.target.checked } }))} className="size-4 rounded border-slate-300 text-brand-700 focus:ring-brand-500" />{edit.confirmed ? <><Check className="size-3 text-success" /> Ja</> : "Nog niet"}</label></div>; })}</div></div><p className="mt-2 text-xs text-slate-500">Gebruik expliciet <strong>0</strong> voor “niet geleverd” en bevestig ook die regel afzonderlijk.</p></fieldset>)}</div>
            </div>
            {selectedDraft.status !== "posted" && <div className="grid gap-3 border-t border-line bg-slate-50/70 p-6 sm:grid-cols-2"><button type="button" onClick={() => void saveDraft()} disabled={saving} className="flex h-11 items-center justify-center gap-2 rounded-lg border border-brand-700 bg-white text-sm font-semibold text-brand-700 hover:bg-brand-50 disabled:opacity-60">{saving ? <Loader2 className="size-4 animate-spin" /> : <Check className="size-4" />} Concept opslaan</button><button type="button" onClick={() => void postDraft()} disabled={saving || selectedDraft.status !== "ready" || !overview.enabled} className="flex h-11 items-center justify-center gap-2 rounded-lg bg-brand-700 text-sm font-semibold text-white hover:bg-brand-900 disabled:bg-slate-300"><Package className="size-4" /> Totale levering boeken</button><p className="sm:col-span-2 text-center text-xs text-slate-500">Boeken is één transactie: journaal, fysieke voorraad, FIFO-allocaties, audit en actiepunten.</p></div>}
            {selectedDraft.status === "posted" && (
              <DeliveryNotificationProposalPanel draftId={selectedDraft.id} />
            )}
          </>}
        </section>
      </div>

      <section className="mt-6 overflow-hidden rounded-2xl border border-line bg-white shadow-card">
        <div className="border-b border-line px-6 py-5"><h2 className="text-base font-bold text-brand-900">Voorraad en vraag per maat</h2><p className="mt-1 text-xs text-slate-500">Open vraag telt betaald én onbetaald; alleen betaald plus bevestigde maat kan worden gereserveerd.</p></div>
        <div className="overflow-x-auto"><table className="min-w-full text-left text-xs"><thead className="bg-slate-50 text-xs uppercase tracking-[0.08em] text-slate-500"><tr><th className="px-6 py-3">Variant</th><th className="px-3 py-3">Fysiek</th><th className="px-3 py-3">Gereserveerd</th><th className="px-3 py-3">Vrij</th><th className="px-3 py-3">Totale vraag</th><th className="px-3 py-3">Betaald wacht</th><th className="px-3 py-3">Onbetaald</th><th className="px-6 py-3">Tekort</th></tr></thead><tbody className="divide-y divide-line">{overview.variants.length === 0 ? <tr><td colSpan={8} className="px-6 py-12 text-center text-slate-500">Nog geen actieve producten en maten in dit seizoen.</td></tr> : overview.variants.map((variant) => <tr key={variant.id}><td className="px-6 py-4"><p className="font-semibold text-ink">{variant.article} · {variant.size}</p><p className="mt-1 text-xs text-slate-500">{variant.sku ?? "Geen SKU"}</p></td><td className="px-3 py-4 text-slate-600">{variant.onHand}</td><td className="px-3 py-4 text-slate-600">{variant.reserved}</td><td className="px-3 py-4 font-bold text-success">{variant.available}</td><td className="px-3 py-4 text-slate-600">{variant.totalOpenDemand}</td><td className="px-3 py-4 text-slate-600">{variant.paidWaiting}</td><td className="px-3 py-4 text-slate-600">{variant.unpaidDemand}</td><td className="px-6 py-4"><span className={`rounded-full px-2.5 py-1 text-xs font-semibold ${variant.shortage > 0 ? "bg-red-50 text-danger" : "bg-emerald-50 text-success"}`}>{variant.shortage}</span></td></tr>)}</tbody></table></div>
      </section>

      <section className="mt-6 rounded-2xl border border-line bg-white p-6 shadow-card">
        <div className="flex items-center justify-between gap-3"><div><h2 className="text-base font-bold text-brand-900">FIFO-wachtlijst</h2><p className="mt-1 text-xs text-slate-500">Prioriteit start op het latere tijdstip van definitieve betaling en geldige maat.</p></div><span className="rounded-full bg-slate-100 px-3 py-1 text-xs font-bold text-slate-600">{overview.waitlist.length} regels</span></div>
        <div className="mt-4 grid gap-2 lg:grid-cols-2">{overview.waitlist.length === 0 ? <p className="rounded-xl border border-dashed border-line p-6 text-center text-xs text-slate-500 lg:col-span-2">Geen open orderregels.</p> : overview.waitlist.map((line) => <div key={line.orderLineId} className="flex min-h-16 items-center gap-3 rounded-xl border border-line px-4 py-3"><div className={`flex size-8 shrink-0 items-center justify-center rounded-full ${line.eligible ? "bg-emerald-50 text-success" : "bg-amber-50 text-warning"}`}>{line.eligible ? <CheckCircle2 className="size-4" /> : <X className="size-4" />}</div><div className="min-w-0 flex-1"><p className="truncate text-xs font-semibold text-ink">{line.memberName}</p><p className="mt-1 truncate text-xs text-slate-500">{line.team ?? "Geen team"} · {line.relationNumber ?? "Geen relatienummer"}</p></div><div className="text-right text-xs font-bold"><p className={line.paid ? "text-success" : "text-warning"}>{line.paid ? "Betaald" : "Onbetaald"}</p><p className={line.sizeValid ? "mt-1 text-success" : "mt-1 text-warning"}>{line.sizeValid ? "Maat geldig" : "Maat open"}</p></div></div>)}</div>
      </section>
      {overview.role === "beheerder" && <InventoryReconciliationPanel
        seasons={overview.seasons}
        blockerCount={blockers}
        onChanged={() => load(overview.seasonId, selectedDraftId)}
      />}
      {overview.role === "beheerder" && <InventoryThresholdControl
        seasonId={overview.seasonId}
        threshold={overview.lowStockThreshold}
        onSaved={async (message) => {
          setSuccess(message);
          await load(overview.seasonId, selectedDraftId);
        }}
        onError={setError}
      />}
    </div>
  );
}
