"use client";

import { AlertTriangle, CheckCircle2, ClipboardCheck, Loader2, Package, Plus, RefreshCw, Users } from "lucide-react";
import { FormEvent, useCallback, useEffect, useMemo, useState } from "react";

type Variant = { id: string; article: string; size: string; sku: string | null; received: number; reserved: number; issued: number; available: number; backorderCount: number };
type ReceiptLine = { id: string; receiptId: string; receivedOn: string; supplier: string; packingSlipReference: string | null; variantId: string; article: string; size: string; received: number; reserved: number; issued: number; available: number };
type WaitlistLine = { orderLineId: string; orderId: string; memberName: string; relationNumber: string; team: string; quantity: number; paid: boolean; createdAt: string };
type Overview = { variants: Variant[]; receiptLines: ReceiptLine[]; waitlist: WaitlistLine[] };

const emptyOverview: Overview = { variants: [], receiptLines: [], waitlist: [] };

export function DeliveriesWorkspace() {
  const [overview, setOverview] = useState<Overview>(emptyOverview);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [receivedOn, setReceivedOn] = useState(() => new Date().toISOString().slice(0, 10));
  const [supplier, setSupplier] = useState("");
  const [packingSlip, setPackingSlip] = useState("");
  const [variantId, setVariantId] = useState("");
  const [quantity, setQuantity] = useState(1);
  const [receiptLineId, setReceiptLineId] = useState("");
  const [selectedOrderLines, setSelectedOrderLines] = useState<string[]>([]);

  const load = useCallback(async (selectedVariantId?: string) => {
    setLoading(true);
    setError(null);
    try {
      const query = selectedVariantId ? `?variantId=${encodeURIComponent(selectedVariantId)}` : "";
      const response = await fetch(`/api/stock/overview${query}`, { cache: "no-store" });
      const payload = await response.json() as Overview & { error?: string };
      if (!response.ok) throw new Error(payload.error ?? "Het voorraadoverzicht kon niet worden geladen.");
      setOverview(payload);
      if (payload.variants[0]) setVariantId((current) => current || payload.variants[0].id);
    } catch (loadError) {
      setError(loadError instanceof Error ? loadError.message : "Het voorraadoverzicht kon niet worden geladen.");
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { void load(); }, [load]);

  async function createReceipt(event: FormEvent) {
    event.preventDefault();
    setSaving(true);
    setError(null);
    setSuccess(null);
    try {
      const response = await fetch("/api/stock/receipts", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          receivedOn,
          supplier,
          packingSlipReference: packingSlip.trim() || undefined,
          lines: [{ variantId, quantity }],
        }),
      });
      const payload = await response.json() as { error?: string };
      if (!response.ok) throw new Error(payload.error ?? "De levering kon niet worden opgeslagen.");
      setSupplier("");
      setPackingSlip("");
      setQuantity(1);
      setSuccess("Levering veilig geregistreerd.");
      await load();
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : "De levering kon niet worden opgeslagen.");
    } finally {
      setSaving(false);
    }
  }

  async function selectReceiptLine(id: string) {
    setReceiptLineId(id);
    setSelectedOrderLines([]);
    const line = overview.receiptLines.find((item) => item.id === id);
    if (line) await load(line.variantId);
  }

  async function reserveSelected() {
    if (!receiptLineId || selectedOrderLines.length === 0) return;
    setSaving(true);
    setError(null);
    setSuccess(null);
    try {
      const response = await fetch("/api/stock/reservations", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ receiptLineId, orderLineIds: selectedOrderLines }),
      });
      const payload = await response.json() as { error?: string };
      if (!response.ok) throw new Error(payload.error ?? "De reservering kon niet worden bevestigd.");
      const line = overview.receiptLines.find((item) => item.id === receiptLineId);
      setSelectedOrderLines([]);
      setSuccess(`${selectedOrderLines.length} ${selectedOrderLines.length === 1 ? "artikelregel" : "artikelregels"} op Af te halen gezet.`);
      await load(line?.variantId);
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : "De reservering kon niet worden bevestigd.");
    } finally {
      setSaving(false);
    }
  }

  const selectedReceipt = overview.receiptLines.find((line) => line.id === receiptLineId);
  const selectedQuantity = overview.waitlist.filter((line) => selectedOrderLines.includes(line.orderLineId)).reduce((sum, line) => sum + line.quantity, 0);
  const totals = useMemo(() => overview.variants.reduce((result, item) => ({ received: result.received + item.received, reserved: result.reserved + item.reserved, available: result.available + item.available }), { received: 0, reserved: 0, available: 0 }), [overview.variants]);

  if (loading && overview.variants.length === 0) return <div className="mx-auto max-w-[1200px] animate-pulse"><div className="h-9 w-64 rounded bg-slate-200" /><div className="mt-8 grid gap-5 md:grid-cols-3"><div className="h-28 rounded-2xl bg-white" /><div className="h-28 rounded-2xl bg-white" /><div className="h-28 rounded-2xl bg-white" /></div></div>;

  return (
    <div className="mx-auto max-w-[1240px]">
      <div className="flex flex-col justify-between gap-4 md:flex-row md:items-end"><div><p className="text-xs font-bold uppercase tracking-[0.14em] text-brand-500">Voorraad en reservering</p><h1 className="mt-2 text-3xl font-bold tracking-tight text-brand-900">Leveringen</h1><p className="mt-2 text-sm text-slate-500">Registreer ontvangen varianten en wijs fysiek beschikbare stuks toe aan de wachtlijst.</p></div><button onClick={() => void load(selectedReceipt?.variantId)} disabled={loading} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-line bg-white px-3.5 text-xs font-semibold text-slate-600 hover:border-brand-500 disabled:opacity-60"><RefreshCw className={`size-3.5 ${loading ? "animate-spin" : ""}`} /> Vernieuwen</button></div>

      {(error || success) && <div role={error ? "alert" : "status"} className={`mt-5 flex items-start gap-2 rounded-xl border p-4 text-xs ${error ? "border-red-100 bg-red-50 text-danger" : "border-emerald-100 bg-emerald-50 text-success"}`}>{error ? <AlertTriangle className="size-4 shrink-0" /> : <CheckCircle2 className="size-4 shrink-0" />}{error ?? success}</div>}

      <div className="mt-6 grid gap-4 sm:grid-cols-3">{[{ label: "Ontvangen", value: totals.received, icon: Package }, { label: "Gereserveerd", value: totals.reserved, icon: ClipboardCheck }, { label: "Beschikbaar", value: totals.available, icon: CheckCircle2 }].map((item) => { const Icon = item.icon; return <div key={item.label} className="rounded-2xl border border-line bg-white p-5 shadow-card"><div className="flex items-center justify-between"><p className="text-xs font-semibold text-slate-500">{item.label}</p><Icon className="size-4 text-brand-500" /></div><p className="mt-3 text-2xl font-bold text-brand-900">{item.value}</p><p className="mt-1 text-[10px] text-slate-400">stuks over alle actieve varianten</p></div>; })}</div>

      <div className="mt-6 grid gap-6 xl:grid-cols-[420px_1fr]">
        <form onSubmit={(event) => void createReceipt(event)} className="rounded-2xl border border-line bg-white p-6 shadow-card"><div className="flex items-center gap-3"><div className="flex size-10 items-center justify-center rounded-xl bg-brand-50 text-brand-700"><Plus className="size-4" /></div><div><p className="text-[10px] font-bold uppercase tracking-[0.12em] text-slate-400">Nieuwe ontvangst</p><h2 className="mt-1 text-base font-bold text-brand-900">Levering registreren</h2></div></div><div className="mt-6 grid gap-4"><label className="text-xs font-semibold text-ink">Ontvangstdatum<input type="date" value={receivedOn} onChange={(event) => setReceivedOn(event.target.value)} required className="mt-2 h-11 w-full rounded-lg border border-line px-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></label><label className="text-xs font-semibold text-ink">Leverancier<input value={supplier} onChange={(event) => setSupplier(event.target.value)} required maxLength={160} placeholder="Naam leverancier" className="mt-2 h-11 w-full rounded-lg border border-line px-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></label><label className="text-xs font-semibold text-ink">Pakbonreferentie<input value={packingSlip} onChange={(event) => setPackingSlip(event.target.value)} maxLength={160} placeholder="Optioneel" className="mt-2 h-11 w-full rounded-lg border border-line px-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></label><label className="text-xs font-semibold text-ink">Artikelvariant<select value={variantId} onChange={(event) => setVariantId(event.target.value)} required className="mt-2 h-11 w-full rounded-lg border border-line bg-white px-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100"><option value="">Selecteer variant</option>{overview.variants.map((variant) => <option key={variant.id} value={variant.id}>{variant.article} · {variant.size}</option>)}</select></label><label className="text-xs font-semibold text-ink">Ontvangen aantal<input type="number" min={1} max={10000} value={quantity} onChange={(event) => setQuantity(Number(event.target.value))} required className="mt-2 h-11 w-full rounded-lg border border-line px-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></label></div><button disabled={saving || !variantId} className="mt-6 flex h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 text-sm font-semibold text-white hover:bg-brand-900 disabled:bg-slate-300">{saving ? <Loader2 className="size-4 animate-spin" /> : <Package className="size-4" />} Levering opslaan</button></form>

        <section className="rounded-2xl border border-line bg-white shadow-card"><div className="border-b border-line p-6"><div className="flex items-center gap-3"><div className="flex size-10 items-center justify-center rounded-xl bg-brand-50 text-brand-700"><Users className="size-4" /></div><div><p className="text-[10px] font-bold uppercase tracking-[0.12em] text-slate-400">Wachtlijst</p><h2 className="mt-1 text-base font-bold text-brand-900">Voorraad toewijzen</h2></div></div><label className="mt-5 block text-xs font-semibold text-ink">Beschikbare ontvangstregel<select value={receiptLineId} onChange={(event) => void selectReceiptLine(event.target.value)} className="mt-2 h-11 w-full rounded-lg border border-line bg-white px-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100"><option value="">Selecteer ontvangen voorraad</option>{overview.receiptLines.filter((line) => line.available > 0).map((line) => <option key={line.id} value={line.id}>{line.article} · {line.size} — {line.available} beschikbaar — {line.supplier}</option>)}</select></label>{selectedReceipt && <div className="mt-4 grid grid-cols-3 gap-3 rounded-xl bg-slate-50 p-4 text-center"><div><p className="text-[10px] text-slate-400">Ontvangen</p><p className="mt-1 text-sm font-bold text-ink">{selectedReceipt.received}</p></div><div><p className="text-[10px] text-slate-400">Al toegewezen</p><p className="mt-1 text-sm font-bold text-ink">{selectedReceipt.reserved + selectedReceipt.issued}</p></div><div><p className="text-[10px] text-slate-400">Beschikbaar</p><p className="mt-1 text-sm font-bold text-success">{selectedReceipt.available}</p></div></div>}</div>
          <div className="max-h-[480px] overflow-y-auto p-6">{!selectedReceipt ? <div className="py-14 text-center"><ClipboardCheck className="mx-auto size-7 text-slate-300" /><p className="mt-3 text-sm font-semibold text-slate-500">Selecteer eerst een ontvangstregel</p></div> : overview.waitlist.length === 0 ? <div className="py-14 text-center"><CheckCircle2 className="mx-auto size-7 text-success" /><p className="mt-3 text-sm font-semibold text-slate-500">Geen wachtende orderregels voor deze variant</p></div> : <div className="space-y-2">{overview.waitlist.map((line) => { const checked = selectedOrderLines.includes(line.orderLineId); const wouldExceed = !checked && selectedQuantity + line.quantity > selectedReceipt.available; return <label key={line.orderLineId} className={`flex min-h-16 items-center gap-3 rounded-xl border px-4 py-3 ${wouldExceed ? "cursor-not-allowed border-transparent bg-slate-50 opacity-55" : "cursor-pointer border-line hover:border-brand-500"}`}><input type="checkbox" checked={checked} disabled={wouldExceed} onChange={() => setSelectedOrderLines((current) => checked ? current.filter((id) => id !== line.orderLineId) : [...current, line.orderLineId])} className="size-4 rounded border-slate-300 text-brand-700 focus:ring-brand-500" /><span className="min-w-0 flex-1"><span className="block truncate text-xs font-semibold text-ink">{line.memberName}</span><span className="mt-1 block text-[10px] text-slate-400">{line.team} · {line.relationNumber}</span></span><span className={`rounded-full px-2 py-1 text-[9px] font-bold ${line.paid ? "bg-emerald-50 text-success" : "bg-amber-50 text-warning"}`}>{line.paid ? "Betaald" : "Open"}</span></label>; })}</div>}</div>
          <div className="border-t border-line bg-slate-50/70 p-6"><button onClick={() => void reserveSelected()} disabled={saving || selectedOrderLines.length === 0} className="flex h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 text-sm font-semibold text-white hover:bg-brand-900 disabled:bg-slate-300">{saving ? <Loader2 className="size-4 animate-spin" /> : <ClipboardCheck className="size-4" />} Reserveringen bevestigen ({selectedOrderLines.length})</button><p className="mt-2 text-center text-[10px] text-slate-400">De server controleert voorraad opnieuw en voert alles atomair uit.</p></div></section>
      </div>

      <section className="mt-6 overflow-hidden rounded-2xl border border-line bg-white shadow-card"><div className="border-b border-line px-6 py-5"><h2 className="text-base font-bold text-brand-900">Voorraad per variant</h2><p className="mt-1 text-xs text-slate-500">Ontvangen minus actieve reserveringen en uitgegeven stuks.</p></div><div className="overflow-x-auto"><table className="min-w-full text-left text-xs"><thead className="bg-slate-50 text-[10px] uppercase tracking-[0.08em] text-slate-400"><tr><th className="px-6 py-3">Variant</th><th className="px-4 py-3">Ontvangen</th><th className="px-4 py-3">Gereserveerd</th><th className="px-4 py-3">Uitgegeven</th><th className="px-4 py-3">Beschikbaar</th><th className="px-6 py-3">Wachtlijst</th></tr></thead><tbody className="divide-y divide-line">{overview.variants.map((variant) => <tr key={variant.id}><td className="px-6 py-4"><p className="font-semibold text-ink">{variant.article} · {variant.size}</p><p className="mt-1 text-[10px] text-slate-400">{variant.sku ?? "Geen SKU"}</p></td><td className="px-4 py-4 text-slate-600">{variant.received}</td><td className="px-4 py-4 text-slate-600">{variant.reserved}</td><td className="px-4 py-4 text-slate-600">{variant.issued}</td><td className="px-4 py-4 font-bold text-success">{variant.available}</td><td className="px-6 py-4"><span className="rounded-full bg-amber-50 px-2.5 py-1 text-[10px] font-semibold text-warning">{variant.backorderCount} wachtend</span></td></tr>)}</tbody></table></div></section>
    </div>
  );
}
