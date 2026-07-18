"use client";

import { useMemo, useState } from "react";
import { ClipboardList, Download, FileSpreadsheet, PackageCheck, ReceiptText, Shirt, Users } from "lucide-react";
import { EXPORT_TYPES, type ExportType, type ExportWorkspace as Workspace } from "@/lib/export-contract";

const meta: Record<ExportType, { label: string; description: string; icon: typeof Users }> = {
  members: { label: "Leden", description: "Relatienummer, team, e-mail, activatie en ouderkoppeling.", icon: Users },
  orders: { label: "Bestellingen", description: "Bedragen, betaalstatus, orderstatus en artikeltellingen.", icon: ClipboardList },
  payments: { label: "Betalingen", description: "Methode, status, referentie, datum en verantwoordelijke.", icon: ReceiptText },
  deliveries: { label: "Leveringen", description: "Ontvangen, gereserveerde en beschikbare voorraad per variant.", icon: PackageCheck },
  fulfilments: { label: "Uitgiftes", description: "Uitgegeven artikelregels, datum, medewerker en correctiestatus.", icon: Shirt },
  outstanding: { label: "Openstaand", description: "Onbetaalde, nageleverde en nog niet opgehaalde regels.", icon: FileSpreadsheet },
};

export function ExportWorkspace({ workspace }: { workspace: Workspace }) {
  const initialSeason = workspace.seasons.find((season) => season.active)?.id ?? "";
  const [type, setType] = useState<ExportType>("members");
  const [seasonId, setSeasonId] = useState(initialSeason);
  const [filter, setFilter] = useState("");
  const filterOptions = workspace.filters[type];
  const links = useMemo(() => {
    const query = new URLSearchParams();
    if (seasonId) query.set("seasonId", seasonId);
    if (filter) query.set("filter", filter);
    return (format: "csv" | "xlsx") => {
      const params = new URLSearchParams(query);
      params.set("format", format);
      return `/api/exports/${type}?${params.toString()}`;
    };
  }, [filter, seasonId, type]);

  function selectType(next: ExportType) {
    setType(next);
    setFilter("");
  }

  return <div className="mx-auto max-w-[1400px]">
    <header><p className="text-xs font-semibold uppercase tracking-[0.12em] text-brand-500">Gecontroleerde gegevensuitvoer</p><h1 className="mt-2 text-[30px] font-bold tracking-[-0.04em] text-brand-900 md:text-[34px]">Exports</h1><p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">Maak een actuele, server-side gevalideerde export. Iedere uitvoer wordt geregistreerd in het auditlog; browserfilters bepalen nooit zelfstandig welke gegevens worden vrijgegeven.</p></header>

    <section className="mt-7 grid gap-3 sm:grid-cols-2 xl:grid-cols-3" aria-label="Exportsoort">
      {EXPORT_TYPES.map((item) => {
        const Icon = meta[item].icon;
        const active = item === type;
        return <button key={item} type="button" onClick={() => selectType(item)} aria-pressed={active} className={`rounded-xl border p-5 text-left shadow-card transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2 ${active ? "border-brand-500 bg-brand-50/60" : "border-line bg-white hover:border-brand-200"}`}>
          <div className="flex items-start gap-4"><span className={`flex size-10 shrink-0 items-center justify-center rounded-lg ${active ? "bg-brand-700 text-white" : "bg-slate-100 text-slate-500"}`}><Icon className="size-5" aria-hidden="true" /></span><span><span className="block text-sm font-bold text-brand-900">{meta[item].label}</span><span className="mt-1 block text-xs leading-5 text-slate-500">{meta[item].description}</span></span></div>
        </button>;
      })}
    </section>

    <section className="mt-6 rounded-xl border border-line bg-white shadow-card">
      <div className="border-b border-line px-6 py-5"><h2 className="text-base font-bold text-brand-900">Selectie voor {meta[type].label.toLocaleLowerCase("nl-NL")}</h2><p className="mt-1 text-xs text-slate-500">Kies een seizoen en, waar beschikbaar, een aanvullende statusfilter.</p></div>
      <div className="grid gap-5 p-6 md:grid-cols-2">
        <label className="block"><span className="mb-2 block text-xs font-bold text-brand-900">Seizoen</span><select value={seasonId} onChange={(event) => setSeasonId(event.target.value)} className="h-11 w-full rounded-lg border border-line bg-white px-3 text-sm text-ink outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100"><option value="">Alle seizoenen</option>{workspace.seasons.map((season) => <option key={season.id} value={season.id}>{season.name}{season.active ? " — actief" : ""}</option>)}</select></label>
        <label className="block"><span className="mb-2 block text-xs font-bold text-brand-900">Statusfilter</span><select value={filter} onChange={(event) => setFilter(event.target.value)} disabled={filterOptions.length === 0} className="h-11 w-full rounded-lg border border-line bg-white px-3 text-sm text-ink outline-none disabled:bg-slate-50 disabled:text-slate-400 focus:border-brand-500 focus:ring-2 focus:ring-brand-100"><option value="">{filterOptions.length === 0 ? "Geen aanvullende filter" : "Alle statussen"}</option>{filterOptions.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}</select></label>
      </div>
      <div className="flex flex-col gap-3 border-t border-line bg-slate-50/60 px-6 py-5 sm:flex-row sm:items-center sm:justify-between">
        <p className="max-w-2xl text-[11px] leading-5 text-slate-500">CSV gebruikt UTF-8 met BOM en is geschikt voor Nederlandse Excel-instellingen. Formulegevoelige waarden worden in CSV én XLSX onschadelijk gemaakt.</p>
        <div className="flex gap-2"><a href={links("csv")} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-brand-200 bg-white px-4 text-xs font-bold text-brand-700 hover:bg-brand-50 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500"><Download className="size-4" aria-hidden="true" /> CSV</a><a href={links("xlsx")} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-bold text-white hover:bg-brand-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2"><FileSpreadsheet className="size-4" aria-hidden="true" /> Excel</a></div>
      </div>
    </section>
  </div>;
}

