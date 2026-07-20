"use client";

import { AlertTriangle, CheckCircle2, CircleDot, Edit3, Layers3, Link2, Loader2, Package, Plus, Power, Shirt, Unlink2 } from "lucide-react";
import { FormEvent, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import type { CatalogOrderWorkspace as Workspace } from "@/lib/catalog-order-contract";

type Article = Workspace["articles"][number];
type Variant = Article["variants"][number];
type Notice = { tone: "error" | "success"; text: string } | null;

const fieldClass = "mt-2 h-11 w-full rounded-lg border border-line bg-white px-3 text-sm outline-none transition focus:border-brand-500 focus:ring-2 focus:ring-brand-100 disabled:bg-slate-50 disabled:text-slate-400";

function ArticleIcon({ type }: { type: Article["iconType"] }) {
  const Icon = type === "shirt" ? Shirt : type === "circle-dot" ? CircleDot : Package;
  return <Icon className="size-5" strokeWidth={1.7} />;
}

async function postJson(path: string, body: unknown) {
  const response = await fetch(path, { method: "POST", headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" }, body: JSON.stringify(body) });
  const payload = await response.json() as { error?: string };
  if (!response.ok) throw new Error(payload.error ?? "De wijziging kon niet worden opgeslagen.");
}

export function CatalogWorkspace({ workspace }: { workspace: Workspace }) {
  const router = useRouter();
  const [selectedId, setSelectedId] = useState<string | "new">(workspace.articles[0]?.id ?? "new");
  const [variantId, setVariantId] = useState<string | "new">("new");
  const [notice, setNotice] = useState<Notice>(null);
  const [saving, setSaving] = useState(false);
  const selected = workspace.articles.find((article) => article.id === selectedId) ?? null;
  const variant = selected?.variants.find((item) => item.id === variantId) ?? null;
  const totalVariants = workspace.articles.reduce((sum, article) => sum + article.variants.length, 0);
  const available = workspace.articles.reduce((sum, article) => sum + article.variants.reduce((subtotal, item) => subtotal + Math.max(0, item.availableQuantity), 0), 0);

  async function mutate(path: string, body: unknown, success: string) {
    setSaving(true);
    setNotice(null);
    try {
      await postJson(path, body);
      setNotice({ tone: "success", text: success });
      router.refresh();
    } catch (error) {
      setNotice({ tone: "error", text: error instanceof Error ? error.message : "De wijziging kon niet worden opgeslagen." });
    } finally {
      setSaving(false);
    }
  }

  return <div className="mx-auto max-w-[1400px]">
    <header className="flex flex-col gap-5 sm:flex-row sm:items-end sm:justify-between">
      <div><p className="text-xs font-semibold uppercase tracking-[0.12em] text-brand-500">Operationele catalogus</p><h1 className="mt-2 text-[30px] font-bold tracking-[-0.04em] text-brand-900 md:text-[34px]">Artikelen en maten</h1><p className="mt-2 text-sm text-slate-500">Beheer tenueonderdelen en varianten. Bedragen horen uitsluitend bij bestellingen.</p></div>
      <button type="button" onClick={() => { setSelectedId("new"); setVariantId("new"); setNotice(null); }} disabled={!workspace.activeSeason} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:opacity-50"><Plus className="size-4" /> Artikel toevoegen</button>
    </header>

    {!workspace.activeSeason && <div className="mt-6 rounded-xl border border-amber-200 bg-amber-50 p-5"><h2 className="text-sm font-bold text-amber-900">Geen open actief seizoen</h2><p className="mt-1 text-xs leading-5 text-amber-800">De catalogus blijft leesbaar, maar een artikel kan pas veilig worden opgeslagen wanneer een open seizoen actief is.</p></div>}
    {notice && <div role={notice.tone === "error" ? "alert" : "status"} className={"mt-6 flex items-start gap-2 rounded-xl border p-4 text-xs " + (notice.tone === "error" ? "border-red-100 bg-red-50 text-danger" : "border-emerald-100 bg-emerald-50 text-success")}>{notice.tone === "error" ? <AlertTriangle className="size-4 shrink-0" /> : <CheckCircle2 className="size-4 shrink-0" />}{notice.text}</div>}

    <section className="mt-6 grid gap-4 sm:grid-cols-3">
      {[{ label: "Artikelen", value: workspace.articles.length }, { label: "Varianten", value: totalVariants }, { label: "Beschikbaar", value: available }].map((metric) => <div key={metric.label} className="rounded-xl border border-line bg-white px-5 py-4 shadow-card"><p className="text-[10px] font-bold uppercase tracking-[0.1em] text-slate-400">{metric.label}</p><p className="mt-2 text-2xl font-bold text-brand-900">{metric.value.toLocaleString("nl-NL")}</p></div>)}
    </section>

    <div className="mt-6 grid items-start gap-6 xl:grid-cols-[340px_minmax(0,1fr)]">
      <aside className="overflow-hidden rounded-xl border border-line bg-white shadow-card">
        <div className="border-b border-line px-5 py-4"><h2 className="text-sm font-bold text-brand-900">Catalogus</h2><p className="mt-1 text-[11px] text-slate-400">{workspace.activeSeason ? "Gekoppeld aan " + workspace.activeSeason.name : "Alle bekende artikelen"}</p></div>
        {workspace.articles.length === 0 ? <div className="px-6 py-16 text-center"><Package className="mx-auto size-8 text-slate-300" /><p className="mt-4 text-sm font-semibold text-slate-600">Nog geen artikelen</p><p className="mt-1 text-xs leading-5 text-slate-400">Voeg het eerste tenueonderdeel toe zodra een seizoen actief is.</p></div> : <div className="divide-y divide-line">{workspace.articles.map((article) => <button key={article.id} type="button" onClick={() => { setSelectedId(article.id); setVariantId("new"); setNotice(null); }} className={"flex w-full items-center gap-3 px-4 py-4 text-left transition " + (selectedId === article.id ? "bg-brand-50" : "hover:bg-slate-50")}><span className={"flex size-10 shrink-0 items-center justify-center rounded-xl " + (article.active ? "bg-brand-50 text-brand-700" : "bg-slate-100 text-slate-400")}><ArticleIcon type={article.iconType} /></span><span className="min-w-0 flex-1"><span className="flex items-center gap-2"><span className="truncate text-sm font-bold text-brand-900">{article.name}</span>{!article.active && <span className="rounded bg-slate-100 px-1.5 py-0.5 text-[9px] font-bold uppercase text-slate-500">Inactief</span>}</span><span className="mt-1 block text-[11px] text-slate-400">{article.code} · {article.variants.length} maten · {article.seasonIds.length} seizoen{article.seasonIds.length === 1 ? "" : "en"}</span></span></button>)}</div>}
      </aside>

      <div className="space-y-6">
        <BulkSeasonManager workspace={workspace} saving={saving} onSave={(body, message) => void mutate("/api/catalog/article-seasons", body, message)} />
        <ArticleEditor article={selected} activeSeasonId={workspace.activeSeason?.id ?? null} saving={saving} onSave={(body, message) => void mutate("/api/catalog/articles", body, message)} />
        {selected && <VariantManager article={selected} selected={variant} selectedId={variantId} saving={saving} onSelect={setVariantId} onSave={(body, message) => void mutate("/api/catalog/variants", body, message)} />}
      </div>
    </div>
  </div>;
}

function BulkSeasonManager({ workspace, saving, onSave }: { workspace: Workspace; saving: boolean; onSave: (body: unknown, message: string) => void }) {
  const openSeasons = workspace.seasons.filter((season) => season.status === "open");
  const [seasonId, setSeasonId] = useState(workspace.activeSeason?.id ?? openSeasons[0]?.id ?? "");
  const [selectedIds, setSelectedIds] = useState<string[]>([]);
  const selectedSeason = workspace.seasons.find((season) => season.id === seasonId);
  const linkedCount = workspace.articles.filter((article) => article.seasonIds.includes(seasonId)).length;
  function toggle(articleId: string, checked: boolean) {
    setSelectedIds((current) => checked ? [...new Set([...current, articleId])] : current.filter((id) => id !== articleId));
  }
  function save(linked: boolean) {
    onSave({ seasonId, articleIds: selectedIds, linked }, `${selectedIds.length} artikel${selectedIds.length === 1 ? "" : "en"} ${linked ? "gekoppeld aan" : "ontkoppeld van"} ${selectedSeason?.name ?? "het seizoen"}.`);
  }

  return <section className="overflow-hidden rounded-xl border border-line bg-white shadow-card">
    <div className="flex flex-col gap-3 border-b border-line px-6 py-5 sm:flex-row sm:items-start sm:justify-between"><div className="flex items-start gap-3"><span className="flex size-10 shrink-0 items-center justify-center rounded-xl bg-brand-50 text-brand-700"><Layers3 className="size-5" /></span><div><h2 className="text-base font-bold text-brand-900">Artikelen in bulk per seizoen</h2><p className="mt-1 text-xs text-slate-500">Koppel of ontkoppel meerdere artikelen tegelijk. Bestaande bestellingen en artikelregels blijven behouden.</p></div></div><span className="shrink-0 rounded-full bg-brand-50 px-3 py-1 text-[10px] font-bold text-brand-700">{linkedCount} gekoppeld</span></div>
    {openSeasons.length === 0 ? <p className="p-6 text-xs text-slate-500">Maak eerst een open seizoen aan via Instellingen.</p> : <div className="p-6">
      <label className="block text-xs font-semibold text-ink">Open seizoen<select className={fieldClass} value={seasonId} onChange={(event) => { setSeasonId(event.target.value); setSelectedIds([]); }}>{openSeasons.map((season) => <option key={season.id} value={season.id}>{season.name}{season.active ? " · actief" : ""}</option>)}</select></label>
      {workspace.articles.length === 0 ? <p className="mt-4 rounded-lg bg-slate-50 p-4 text-xs text-slate-500">Er zijn nog geen artikelen om te koppelen.</p> : <fieldset disabled={saving} className="mt-4"><div className="flex items-center justify-between border-b border-line pb-3"><label className="flex items-center gap-2 text-xs font-bold text-brand-900"><input type="checkbox" checked={selectedIds.length === workspace.articles.length} onChange={(event) => setSelectedIds(event.target.checked ? workspace.articles.map((article) => article.id) : [])} className="size-4 accent-brand-700" />Alles selecteren</label><span className="text-[10px] text-slate-400">{selectedIds.length} geselecteerd</span></div><div className="grid max-h-64 gap-2 overflow-y-auto py-3 sm:grid-cols-2">{workspace.articles.map((article) => { const linked = article.seasonIds.includes(seasonId); return <label key={article.id} className="flex cursor-pointer items-center gap-3 rounded-lg border border-line p-3 hover:bg-slate-50"><input type="checkbox" checked={selectedIds.includes(article.id)} onChange={(event) => toggle(article.id, event.target.checked)} className="size-4 shrink-0 accent-brand-700" /><span className="min-w-0 flex-1"><span className="block truncate text-xs font-semibold text-ink">{article.name}</span><span className={"mt-0.5 block text-[10px] font-semibold " + (linked ? "text-success" : "text-slate-400")}>{linked ? "Al gekoppeld" : "Niet gekoppeld"}</span></span></label>; })}</div></fieldset>}
      <div className="mt-3 flex flex-col gap-2 sm:flex-row sm:justify-end"><button type="button" onClick={() => save(false)} disabled={saving || selectedIds.length === 0 || !seasonId} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-line px-4 text-xs font-semibold text-slate-600 hover:border-red-200 hover:text-danger disabled:opacity-50"><Unlink2 className="size-4" />Ontkoppelen</button><button type="button" onClick={() => save(true)} disabled={saving || selectedIds.length === 0 || !seasonId} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 disabled:opacity-50">{saving ? <Loader2 className="size-4 animate-spin" /> : <Link2 className="size-4" />}Koppelen aan seizoen</button></div>
    </div>}
  </section>;
}

function ArticleEditor({ article, activeSeasonId, saving, onSave }: { article: Article | null; activeSeasonId: string | null; saving: boolean; onSave: (body: unknown, message: string) => void }) {
  const [name, setName] = useState("");
  const [code, setCode] = useState("");
  const [iconType, setIconType] = useState<Article["iconType"]>("package");
  const [sortOrder, setSortOrder] = useState(0);
  const [active, setActive] = useState(true);
  useEffect(() => { setName(article?.name ?? ""); setCode(article?.code ?? ""); setIconType(article?.iconType ?? "package"); setSortOrder(article?.sortOrder ?? 0); setActive(article?.active ?? true); }, [article]);
  const seasonIds = article?.seasonIds.length ? article.seasonIds : activeSeasonId ? [activeSeasonId] : [];
  function submit(event: FormEvent) { event.preventDefault(); onSave({ articleId: article?.id ?? null, name, code, iconType, active, sortOrder, seasonIds }, article ? "Artikel bijgewerkt." : "Artikel toegevoegd."); }
  function inactivate() { if (article) onSave({ articleId: article.id, name, code, iconType, active: false, sortOrder, seasonIds }, "Artikel geïnactiveerd; historische regels blijven behouden."); }

  return <form onSubmit={submit} className="rounded-xl border border-line bg-white p-6 shadow-card">
    <div className="flex flex-col gap-3 border-b border-line pb-5 sm:flex-row sm:items-start sm:justify-between"><div><p className="text-[10px] font-bold uppercase tracking-[0.12em] text-brand-500">{article ? "Artikel bewerken" : "Nieuw artikel"}</p><h2 className="mt-1 text-lg font-bold text-brand-900">{article?.name ?? "Tenueonderdeel toevoegen"}</h2><p className="mt-1 text-xs text-slate-500">Naam en code identificeren dit artikel; er worden geen artikelprijzen opgeslagen.</p></div>{article?.active && <button type="button" onClick={inactivate} disabled={saving} className="inline-flex h-9 items-center gap-2 rounded-lg border border-line px-3 text-xs font-semibold text-slate-600 hover:border-red-200 hover:text-danger disabled:opacity-50"><Power className="size-3.5" /> Inactiveren</button>}</div>
    <fieldset disabled={!activeSeasonId || saving} className="mt-5 grid gap-4 sm:grid-cols-2">
      <label className="text-xs font-semibold text-ink">Naam<input value={name} onChange={(event) => setName(event.target.value)} required maxLength={120} placeholder="Bijv. Trainingsbroek" className={fieldClass} /></label>
      <label className="text-xs font-semibold text-ink">Korte code<input value={code} onChange={(event) => setCode(event.target.value.toUpperCase())} required minLength={2} maxLength={24} pattern="[A-Z0-9_-]{2,24}" placeholder="TRAINBROEK" className={fieldClass} /></label>
      <label className="text-xs font-semibold text-ink">Icoon<select value={iconType} onChange={(event) => setIconType(event.target.value as Article["iconType"])} className={fieldClass}><option value="shirt">Shirt</option><option value="package">Pakket</option><option value="circle-dot">Rond artikel</option></select></label>
      <label className="text-xs font-semibold text-ink">Sorteervolgorde<input type="number" value={sortOrder} onChange={(event) => setSortOrder(Number(event.target.value))} min={0} max={10000} required className={fieldClass} /></label>
      <label className="flex items-center gap-3 rounded-lg border border-line p-3 text-xs font-semibold text-ink sm:col-span-2"><input type="checkbox" checked={active} onChange={(event) => setActive(event.target.checked)} className="size-4 accent-brand-700" /> Actief voor operationeel gebruik</label>
    </fieldset>
    <div className="mt-5 flex justify-end"><button type="submit" disabled={!activeSeasonId || saving} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:opacity-50">{saving ? <Loader2 className="size-4 animate-spin" /> : <CheckCircle2 className="size-4" />}{article ? "Wijzigingen opslaan" : "Artikel toevoegen"}</button></div>
  </form>;
}

function VariantManager({ article, selected, selectedId, saving, onSelect, onSave }: { article: Article; selected: Variant | null; selectedId: string | "new"; saving: boolean; onSelect: (id: string | "new") => void; onSave: (body: unknown, message: string) => void }) {
  const [size, setSize] = useState("");
  const [supplierCode, setSupplierCode] = useState("");
  const [sortOrder, setSortOrder] = useState(0);
  const [active, setActive] = useState(true);
  useEffect(() => { setSize(selected?.size ?? ""); setSupplierCode(selected?.supplierCode ?? ""); setSortOrder(selected?.sortOrder ?? article.variants.length * 10); setActive(selected?.active ?? true); }, [selected, article]);
  function submit(event: FormEvent) { event.preventDefault(); onSave({ articleId: article.id, variantId: selected?.id ?? null, size, supplierCode, active, sortOrder }, selected ? "Variant bijgewerkt." : "Variant toegevoegd."); }
  function inactivate(item: Variant) { onSave({ articleId: article.id, variantId: item.id, size: item.size, supplierCode: item.supplierCode, active: false, sortOrder: item.sortOrder }, "Variant geïnactiveerd; historische regels blijven behouden."); }

  return <section className="overflow-hidden rounded-xl border border-line bg-white shadow-card">
    <div className="flex items-center justify-between border-b border-line px-6 py-5"><div><h2 className="text-base font-bold text-brand-900">Maten en varianten</h2><p className="mt-1 text-xs text-slate-500">Één variant per maat. Gebruikte maten blijven historisch onveranderlijk.</p></div><button type="button" onClick={() => onSelect("new")} className="inline-flex h-9 items-center gap-2 rounded-lg border border-line px-3 text-xs font-semibold text-brand-700 hover:border-brand-500"><Plus className="size-3.5" /> Variant</button></div>
    {article.variants.length === 0 ? <div className="px-6 py-10 text-center text-xs text-slate-400">Nog geen varianten voor dit artikel.</div> : <div className="overflow-x-auto"><table className="w-full min-w-[680px] text-left"><thead><tr className="border-b border-line bg-slate-50/70 text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400"><th className="px-6 py-3">Maat</th><th className="px-3 py-3">Leverancierscode</th><th className="px-3 py-3">Ontvangen</th><th className="px-3 py-3">Beschikbaar</th><th className="px-3 py-3">Status</th><th className="px-6 py-3 text-right">Acties</th></tr></thead><tbody className="divide-y divide-line">{article.variants.map((item) => <tr key={item.id} className={selectedId === item.id ? "bg-brand-50/60" : ""}><td className="px-6 py-3 text-xs font-bold text-ink">{item.size}{item.used && <span className="ml-2 text-[9px] font-semibold text-slate-400">gebruikt</span>}</td><td className="px-3 py-3 text-xs text-slate-500">{item.supplierCode ?? "—"}</td><td className="px-3 py-3 text-xs text-slate-600">{item.receivedQuantity}</td><td className="px-3 py-3 text-xs font-semibold text-ink">{item.availableQuantity}</td><td className="px-3 py-3"><span className={"rounded-full px-2 py-1 text-[10px] font-bold " + (item.active ? "bg-emerald-50 text-success" : "bg-slate-100 text-slate-500")}>{item.active ? "Actief" : "Inactief"}</span></td><td className="px-6 py-3 text-right"><button type="button" onClick={() => onSelect(item.id)} className="inline-flex size-8 items-center justify-center rounded-lg text-slate-400 hover:bg-white hover:text-brand-700" aria-label={"Bewerk maat " + item.size}><Edit3 className="size-3.5" /></button>{item.active && <button type="button" onClick={() => inactivate(item)} disabled={saving} className="ml-1 inline-flex size-8 items-center justify-center rounded-lg text-slate-400 hover:bg-red-50 hover:text-danger" aria-label={"Inactiveer maat " + item.size}><Power className="size-3.5" /></button>}</td></tr>)}</tbody></table></div>}
    <form onSubmit={submit} className="border-t border-line bg-slate-50/50 p-6"><div className="flex items-center justify-between"><h3 className="text-sm font-bold text-brand-900">{selected ? "Maat " + selected.size + " bewerken" : "Variant toevoegen"}</h3>{selected && <button type="button" onClick={() => onSelect("new")} className="text-xs font-semibold text-brand-700">Annuleren</button>}</div><fieldset disabled={saving} className="mt-4 grid gap-4 sm:grid-cols-2 xl:grid-cols-4"><label className="text-xs font-semibold text-ink">Maat<input value={size} onChange={(event) => setSize(event.target.value)} required maxLength={80} disabled={Boolean(selected?.used)} className={fieldClass} /></label><label className="text-xs font-semibold text-ink">Leverancierscode<input value={supplierCode} onChange={(event) => setSupplierCode(event.target.value)} maxLength={120} placeholder="Optioneel" className={fieldClass} /></label><label className="text-xs font-semibold text-ink">Volgorde<input type="number" value={sortOrder} onChange={(event) => setSortOrder(Number(event.target.value))} min={0} max={10000} className={fieldClass} /></label><label className="flex h-11 items-center gap-3 self-end rounded-lg border border-line bg-white px-3 text-xs font-semibold text-ink"><input type="checkbox" checked={active} onChange={(event) => setActive(event.target.checked)} className="size-4 accent-brand-700" /> Actief</label></fieldset><div className="mt-4 flex justify-end"><button type="submit" disabled={saving} className="inline-flex h-9 items-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 disabled:opacity-50">{saving ? <Loader2 className="size-3.5 animate-spin" /> : <CheckCircle2 className="size-3.5" />}{selected ? "Variant opslaan" : "Variant toevoegen"}</button></div></form>
  </section>;
}
