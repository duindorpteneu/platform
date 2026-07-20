"use client";

import { AlertTriangle, CheckCircle2, Loader2, Shirt, UsersRound } from "lucide-react";
import { useRouter } from "next/navigation";
import { useMemo, useState } from "react";
import type { CatalogOrderWorkspace, TeamOrderArticlesResponse } from "@/lib/catalog-order-contract";

type Article = CatalogOrderWorkspace["articles"][number];
type Notice = { tone: "error" | "success"; text: string } | null;
const fieldClass = "h-10 w-full rounded-lg border border-line bg-white px-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100 disabled:bg-slate-50 disabled:text-slate-400";

async function requestTeamArticles(body: unknown) {
  const response = await fetch("/api/orders/team-articles", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" },
    body: JSON.stringify(body),
  });
  const payload = await response.json() as TeamOrderArticlesResponse & { error?: string };
  if (!response.ok) throw new Error(payload.error ?? "De teamtoewijzing kon niet worden verwerkt.");
  return payload;
}

export function TeamArticleBulkPanel({ teams, articles, disabled }: { teams: string[]; articles: Article[]; disabled: boolean }) {
  const router = useRouter();
  const [team, setTeam] = useState("");
  const [selections, setSelections] = useState<Record<string, string>>({});
  const [preview, setPreview] = useState<TeamOrderArticlesResponse | null>(null);
  const [notice, setNotice] = useState<Notice>(null);
  const [busy, setBusy] = useState(false);
  const variantIds = useMemo(() => Object.values(selections).filter(Boolean), [selections]);

  function invalidate() {
    setPreview(null);
    setNotice(null);
  }

  async function run(commit: boolean) {
    setBusy(true);
    setNotice(null);
    try {
      const result = await requestTeamArticles({ team, variantIds, previewToken: commit ? preview?.previewToken : undefined, commit });
      setPreview(result);
      if (commit) {
        setNotice({ tone: "success", text: `${result.linesAdded} artikelregels toegevoegd: ${result.ordersCreated} nieuwe en ${result.ordersExtended} bestaande bestellingen bijgewerkt.` });
        router.refresh();
      }
    } catch (error) {
      setNotice({ tone: "error", text: error instanceof Error ? error.message : "De teamtoewijzing kon niet worden verwerkt." });
    } finally {
      setBusy(false);
    }
  }

  return <section className="mt-6 overflow-hidden rounded-xl border border-line bg-white shadow-card">
    <div className="flex flex-col gap-4 border-b border-line px-5 py-5 lg:flex-row lg:items-start lg:justify-between"><div className="flex items-start gap-3"><span className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-brand-50 text-brand-700"><UsersRound className="size-4" /></span><div><h2 className="text-sm font-bold text-brand-900">Artikelen per team toevoegen</h2><p className="mt-1 max-w-2xl text-xs leading-5 text-slate-500">Kies per artikel één maat. Bestaande artikelen en maten worden niet overschreven; betaalde orders en inactieve leden worden overgeslagen.</p></div></div><label className="block min-w-[220px] text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400">Team<select value={team} onChange={(event) => { setTeam(event.target.value); invalidate(); }} disabled={disabled || busy} className={"mt-2 " + fieldClass}><option value="">Kies een team</option>{teams.map((option) => <option key={option} value={option}>{option}</option>)}</select></label></div>

    <fieldset disabled={disabled || busy} className="grid gap-3 p-5 sm:grid-cols-2 xl:grid-cols-3">
      {articles.length === 0 ? <div className="col-span-full rounded-lg border border-dashed border-line px-6 py-8 text-center"><Shirt className="mx-auto size-7 text-slate-300" /><p className="mt-3 text-xs font-semibold text-slate-500">Geen actieve artikelen met maten</p></div> : articles.map((article) => <label key={article.id} className="rounded-lg border border-line p-3 text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400"><span className="normal-case tracking-normal text-xs text-brand-900">{article.name}</span><span className="ml-2 font-normal normal-case tracking-normal text-slate-400">{article.code}</span><select value={selections[article.id] ?? ""} onChange={(event) => { setSelections((current) => ({ ...current, [article.id]: event.target.value })); invalidate(); }} className={"mt-2 " + fieldClass}><option value="">Niet toevoegen</option>{article.variants.map((variant) => <option key={variant.id} value={variant.id}>{variant.size}{variant.supplierCode ? ` · ${variant.supplierCode}` : ""}</option>)}</select></label>)}
    </fieldset>

    {preview && !preview.committed && <div className="mx-5 mb-5 rounded-lg border border-brand-100 bg-brand-50 p-4"><p className="text-xs font-bold text-brand-900">Controle gereed voor {preview.team}</p><div className="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-4"><Metric label="Nieuwe orders" value={preview.ordersCreated} /><Metric label="Uitbreidingen" value={preview.ordersExtended} /><Metric label="Regels erbij" value={preview.linesAdded} /><Metric label="Overgeslagen" value={preview.inactiveMembersSkipped + preview.paidOrdersSkipped} /></div><p className="mt-3 text-[10px] leading-4 text-brand-700">{preview.inactiveMembersSkipped} inactieve leden en {preview.paidOrdersSkipped} betaalde bestellingen worden niet gewijzigd. {preview.unchangedMembers} leden hebben alle gekozen artikelen al.</p></div>}
    {notice && <div role={notice.tone === "error" ? "alert" : "status"} className={"mx-5 mb-5 flex gap-2 rounded-lg border p-3 text-[11px] leading-5 " + (notice.tone === "error" ? "border-red-100 bg-red-50 text-danger" : "border-emerald-100 bg-emerald-50 text-success")}>{notice.tone === "error" ? <AlertTriangle className="mt-0.5 size-3.5 shrink-0" /> : <CheckCircle2 className="mt-0.5 size-3.5 shrink-0" />}{notice.text}</div>}
    <div className="flex flex-col gap-2 border-t border-line bg-slate-50/60 px-5 py-4 sm:flex-row sm:justify-end"><button type="button" disabled={disabled || busy || !team || variantIds.length === 0} onClick={() => run(false)} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-brand-200 bg-white px-4 text-xs font-semibold text-brand-700 hover:border-brand-500 disabled:cursor-not-allowed disabled:opacity-50">{busy ? <Loader2 className="size-4 animate-spin" /> : null}Toewijzing controleren</button><button type="button" disabled={disabled || busy || !preview?.previewToken || preview.committed || preview.linesAdded === 0} onClick={() => run(true)} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:opacity-50"><CheckCircle2 className="size-4" /> Definitief toevoegen</button></div>
  </section>;
}

function Metric({ label, value }: { label: string; value: number }) {
  return <div><p className="text-xl font-bold text-brand-900">{value.toLocaleString("nl-NL")}</p><p className="mt-0.5 text-[9px] font-semibold uppercase tracking-[0.08em] text-brand-500">{label}</p></div>;
}
