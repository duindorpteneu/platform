"use client";

import { AlertTriangle, Loader2, PackageSearch, RefreshCw } from "lucide-react";
import { useEffect, useState } from "react";
import type {
  SupplierContext,
  SupplierPlanning,
} from "@/lib/supplier-contract";

const genderLabel = {
  male: "Jongen/man",
  female: "Meisje/vrouw",
  other: "Anders",
  unknown: "Onbekend",
} as const;

export function SupplierPlanningWorkspace({
  context,
}: {
  context: SupplierContext;
}) {
  const [seasonId, setSeasonId] = useState(
    context.activeSeason?.id ?? context.seasons[0]?.id ?? "",
  );
  const [planning, setPlanning] = useState<SupplierPlanning | null>(null);
  const [loading, setLoading] = useState(Boolean(seasonId));
  const [error, setError] = useState<string | null>(null);

  async function load(selectedSeasonId: string) {
    if (!selectedSeasonId) {
      setPlanning(null);
      setLoading(false);
      return;
    }
    setLoading(true);
    setError(null);
    try {
      const response = await fetch(
        `/api/supplier/planning?seasonId=${encodeURIComponent(selectedSeasonId)}`,
        { credentials: "same-origin", cache: "no-store" },
      );
      const payload = await response.json() as SupplierPlanning & {
        error?: string;
      };
      if (!response.ok) {
        setError(response.status === 403
          ? "De toegang is ingetrokken. Log opnieuw in."
          : payload.error ?? "Planning kon niet worden geladen.");
        setPlanning(null);
        return;
      }
      setPlanning(payload);
    } catch {
      setError("Planning kon niet worden geladen.");
      setPlanning(null);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void load(seasonId);
  }, [seasonId]);

  return <div>
    <header className="flex flex-col gap-5 lg:flex-row lg:items-end lg:justify-between">
      <div>
        <p className="text-xs font-bold uppercase tracking-[0.14em] text-brand-500">Free-Kick planning</p>
        <h1 className="mt-2 text-3xl font-bold tracking-[-0.04em] text-brand-900">Voorraad en open vraag</h1>
        <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">Uitsluitend geaggregeerde aantallen per product, maat en geslacht. Deze werkruimte bevat geen individuele leden- of betaalgegevens.</p>
      </div>
      <div className="flex flex-col gap-3 sm:flex-row">
        <label className="text-xs font-semibold text-ink">Seizoen
          <select value={seasonId} onChange={(event) => setSeasonId(event.target.value)} className="mt-2 h-11 min-w-56 rounded-lg border border-line bg-white px-3 text-sm outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100">
            {context.seasons.map((season) => <option key={season.id} value={season.id}>{season.name}</option>)}
          </select>
        </label>
        <button type="button" onClick={() => void load(seasonId)} disabled={loading || !seasonId} className="mt-auto inline-flex h-11 items-center justify-center gap-2 rounded-lg border border-brand-200 bg-white px-4 text-xs font-bold text-brand-700 hover:bg-brand-50 disabled:opacity-50">
          <RefreshCw className="size-4" />Vernieuwen
        </button>
      </div>
    </header>

    {context.seasons.length === 0 && <Empty text="Voor deze toegang is geen open seizoen vrijgegeven." />}
    {error && <div role="alert" className="mt-6 flex items-start gap-3 rounded-xl border border-red-100 bg-red-50 p-4 text-sm text-danger"><AlertTriangle className="mt-0.5 size-5 shrink-0" />{error}</div>}
    {loading && <div role="status" className="mt-10 flex items-center justify-center gap-3 rounded-xl border border-line bg-white p-12 text-sm text-slate-500"><Loader2 className="size-5 animate-spin text-brand-600" />Planning laden…</div>}

    {!loading && planning && <>
      <section className="mt-6 grid gap-4 sm:grid-cols-3">
        <Metric label="Maatregels" value={planning.inventory.length} />
        <Metric label="Open vraag" value={planning.demandByGender.reduce((total, row) => total + row.totalOpenDemand, 0) + planning.unresolvedSizeDemand.reduce((total, row) => total + row.totalDemand, 0)} />
        <Metric label="Tekort" value={planning.inventory.reduce((total, row) => total + row.shortage, 0)} />
      </section>

      <PlanningTable title="Voorraad per product en maat" description={`Lagevoorraaddrempel: ${planning.lowStockThreshold}. Voorraad is niet geslachtsgebonden.`}>
        <thead><tr><Th>Product</Th><Th>Maat</Th><Th>Code</Th><Th right>Fysiek</Th><Th right>Gereserveerd</Th><Th right>Vrij</Th><Th right>Uitgegeven</Th><Th right>Open vraag</Th><Th right>Tekort</Th></tr></thead>
        <tbody>{planning.inventory.map((row) => <tr key={`${row.productCode}:${row.size}`} className="border-t border-line">
          <Td><span className="font-semibold text-brand-900">{row.productName}</span>{(!row.productActive || !row.variantActive) && <span className="ml-2 rounded bg-slate-100 px-2 py-0.5 text-[10px] text-slate-500">inactief</span>}</Td>
          <Td>{row.size}</Td><Td>{row.supplierCode ?? "—"}</Td><Td right>{row.physical}</Td><Td right>{row.reserved}</Td><Td right>{row.free}</Td><Td right>{row.issued}</Td><Td right>{row.totalOpenDemand}</Td><Td right warning={row.shortage > 0}>{row.shortage}</Td>
        </tr>)}</tbody>
      </PlanningTable>

      <PlanningTable title="Vraag per product, maat en geslacht" description="Inclusief onbetaalde open vraag; betaalstatus is uitsluitend als telling zichtbaar.">
        <thead><tr><Th>Product</Th><Th>Maat</Th><Th>Geslacht</Th><Th right>Open</Th><Th right>Betaald wachtend</Th><Th right>Onbetaald</Th><Th right>Onbevestigd</Th><Th right>Afgehaald</Th></tr></thead>
        <tbody>{planning.demandByGender.map((row) => <tr key={`${row.productCode}:${row.size}:${row.gender}`} className="border-t border-line"><Td><span className="font-semibold text-brand-900">{row.productName}</span></Td><Td>{row.size}</Td><Td>{genderLabel[row.gender]}</Td><Td right>{row.totalOpenDemand}</Td><Td right>{row.paidWaiting}</Td><Td right>{row.unpaidDemand}</Td><Td right>{row.unconfirmedDemand}</Td><Td right>{row.pickedUp}</Td></tr>)}</tbody>
      </PlanningTable>

      {planning.unresolvedSizeDemand.length > 0 && <PlanningTable title="Vraag zonder geldige maatvariant" description="Ontbrekende, onbevestigde en conflicterende maten blijven actiepunten bij de club en worden niet als fictieve SKU getoond.">
        <thead><tr><Th>Product</Th><Th>Geslacht</Th><Th right>Totaal</Th><Th right>Betaald</Th><Th right>Onbetaald</Th><Th right>Ontbreekt</Th><Th right>Onbevestigd</Th><Th right>Conflict</Th></tr></thead>
        <tbody>{planning.unresolvedSizeDemand.map((row) => <tr key={`${row.productCode}:${row.gender}`} className="border-t border-line"><Td><span className="font-semibold text-brand-900">{row.productName}</span></Td><Td>{genderLabel[row.gender]}</Td><Td right>{row.totalDemand}</Td><Td right>{row.paidDemand}</Td><Td right>{row.unpaidDemand}</Td><Td right>{row.missing}</Td><Td right>{row.unconfirmed}</Td><Td right warning={row.conflict > 0}>{row.conflict}</Td></tr>)}</tbody>
      </PlanningTable>}

      <p className="mt-5 text-right text-[11px] text-slate-400">Berekend {new Date(planning.generatedAt).toLocaleString("nl-NL")}</p>
    </>}
  </div>;
}

function Metric({ label, value }: { label: string; value: number }) {
  return <div className="rounded-xl border border-line bg-white p-5 shadow-card"><p className="text-[10px] font-bold uppercase tracking-[0.12em] text-slate-400">{label}</p><p className="mt-2 text-2xl font-bold text-brand-900">{value}</p></div>;
}

function Empty({ text }: { text: string }) {
  return <div className="mt-8 flex flex-col items-center rounded-xl border border-dashed border-line bg-white p-12 text-center"><PackageSearch className="size-9 text-slate-300" /><p className="mt-4 text-sm text-slate-500">{text}</p></div>;
}

function PlanningTable({ title, description, children }: { title: string; description: string; children: React.ReactNode }) {
  return <section className="mt-6 overflow-hidden rounded-xl border border-line bg-white shadow-card"><div className="border-b border-line px-5 py-4"><h2 className="text-sm font-bold text-brand-900">{title}</h2><p className="mt-1 text-[11px] leading-5 text-slate-500">{description}</p></div><div className="overflow-x-auto"><table className="min-w-full text-left text-xs">{children}</table></div></section>;
}

function Th({ children, right = false }: { children: React.ReactNode; right?: boolean }) {
  return <th scope="col" className={`whitespace-nowrap bg-slate-50 px-4 py-3 text-[10px] font-bold uppercase tracking-[0.08em] text-slate-500 ${right ? "text-right" : ""}`}>{children}</th>;
}

function Td({ children, right = false, warning = false }: { children: React.ReactNode; right?: boolean; warning?: boolean }) {
  return <td className={`whitespace-nowrap px-4 py-3 ${right ? "text-right tabular-nums" : ""} ${warning ? "font-bold text-danger" : "text-slate-600"}`}>{children}</td>;
}
