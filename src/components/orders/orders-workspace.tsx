"use client";

import { AlertTriangle, CheckCircle2, CircleOff, ClipboardList, Loader2, LockKeyhole, Search, Shirt, UsersRound } from "lucide-react";
import { FormEvent, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { formatCentsForEuroInput, parseEuroAmountToCents, type CatalogOrderWorkspace as Workspace } from "@/lib/catalog-order-contract";
import { TeamArticleBulkPanel } from "@/components/orders/team-article-bulk-panel";

type Member = Workspace["members"][number];
type Article = Workspace["articles"][number];
type DraftLine = { articleId: string; variantId: string; quantity: number };
type Notice = { tone: "error" | "success"; text: string } | null;

const fieldClass = "h-11 w-full rounded-lg border border-line bg-white px-3 text-sm outline-none transition focus:border-brand-500 focus:ring-2 focus:ring-brand-100 disabled:bg-slate-50 disabled:text-slate-400";
const lineStatusLabels = { backorder: "Nalevering", ready_for_pickup: "Af te halen", picked_up: "Afgehaald", cancelled: "Geannuleerd" } as const;

async function saveOrder(body: unknown) {
  const response = await fetch("/api/orders/save", { method: "POST", headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" }, body: JSON.stringify(body) });
  const payload = await response.json() as { error?: string };
  if (!response.ok) throw new Error(payload.error ?? "De bestelling kon niet worden opgeslagen.");
}

export function OrdersWorkspace({ workspace }: { workspace: Workspace }) {
  const router = useRouter();
  const [search, setSearch] = useState("");
  const [memberId, setMemberId] = useState<string | null>(null);
  const [amount, setAmount] = useState(workspace.activeSeason ? formatCentsForEuroInput(workspace.activeSeason.defaultAmountCents) : "0,00");
  const [lines, setLines] = useState<DraftLine[]>([]);
  const [notice, setNotice] = useState<Notice>(null);
  const [saving, setSaving] = useState(false);
  const selected = workspace.members.find((member) => member.id === memberId) ?? null;

  const filteredMembers = useMemo(() => {
    const query = search.trim().toLocaleLowerCase("nl-NL");
    if (!query) return workspace.members;
    return workspace.members.filter((member) => [member.name, member.relationNumber, member.team].some((value) => value.toLocaleLowerCase("nl-NL").includes(query)));
  }, [search, workspace.members]);

  const editableArticles = useMemo(() => {
    if (!workspace.activeSeason) return [];
    const current = workspace.articles.filter((article) => article.active && article.seasonIds.includes(workspace.activeSeason!.id));
    const existingIds = new Set(selected?.order?.lines.map((line) => line.articleId) ?? []);
    return workspace.articles.filter((article) => current.some((item) => item.id === article.id) || existingIds.has(article.id));
  }, [selected, workspace.activeSeason, workspace.articles]);

  useEffect(() => {
    if (!selected) return;
    setAmount(formatCentsForEuroInput(selected.order?.amountDueCents ?? workspace.activeSeason?.defaultAmountCents ?? 0));
    setLines((selected.order?.lines ?? []).map((line) => ({ articleId: line.articleId, variantId: line.variantId, quantity: line.quantity })));
    setNotice(null);
  }, [selected, workspace.activeSeason?.defaultAmountCents]);

  function chooseMember(member: Member) {
    setMemberId(member.id);
  }

  function updateLine(articleId: string, variantId: string) {
    setLines((current) => {
      const withoutArticle = current.filter((line) => line.articleId !== articleId);
      return variantId ? [...withoutArticle, { articleId, variantId, quantity: current.find((line) => line.articleId === articleId)?.quantity ?? 1 }] : withoutArticle;
    });
  }

  function updateQuantity(articleId: string, quantity: number) {
    setLines((current) => current.map((line) => line.articleId === articleId ? { ...line, quantity } : line));
  }

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (!selected || !workspace.activeSeason || selected.order?.paid) return;
    const amountDueCents = parseEuroAmountToCents(amount);
    if (amountDueCents === null) {
      setNotice({ tone: "error", text: "Voer een exact bedrag in met maximaal twee decimalen, bijvoorbeeld 87,50." });
      return;
    }
    if (lines.length === 0) {
      setNotice({ tone: "error", text: "Selecteer minimaal één artikelvariant." });
      return;
    }
    setSaving(true);
    setNotice(null);
    try {
      await saveOrder({ memberId: selected.id, seasonId: workspace.activeSeason.id, amountDueCents, lines: lines.map((line) => ({ variantId: line.variantId, quantity: line.quantity })) });
      setNotice({ tone: "success", text: selected.order ? "Bestelling bijgewerkt en geaudit." : "Bestelling aangemaakt met het exacte verschuldigde bedrag." });
      router.refresh();
    } catch (error) {
      setNotice({ tone: "error", text: error instanceof Error ? error.message : "De bestelling kon niet worden opgeslagen." });
    } finally {
      setSaving(false);
    }
  }

  const counts = {
    total: workspace.members.length,
    ordered: workspace.members.filter((member) => member.order).length,
    paid: workspace.members.filter((member) => member.order?.paid).length,
  };

  return <div className="mx-auto max-w-[1400px]">
    <header><p className="text-xs font-semibold uppercase tracking-[0.12em] text-brand-500">Orderbeheer</p><h1 className="mt-2 text-[30px] font-bold tracking-[-0.04em] text-brand-900 md:text-[34px]">Bestellingen</h1><p className="mt-2 text-sm text-slate-500">Beheer per actief lid precies één seizoensbestelling met een exact verschuldigd bedrag.</p></header>

    {!workspace.activeSeason && <div className="mt-6 rounded-xl border border-amber-200 bg-amber-50 p-5"><h2 className="text-sm font-bold text-amber-900">Geen open actief seizoen</h2><p className="mt-1 text-xs leading-5 text-amber-800">Nieuwe of gewijzigde bestellingen zijn geblokkeerd totdat een open seizoen actief is.</p></div>}
    {notice && <div role={notice.tone === "error" ? "alert" : "status"} className={"mt-6 flex items-start gap-2 rounded-xl border p-4 text-xs " + (notice.tone === "error" ? "border-red-100 bg-red-50 text-danger" : "border-emerald-100 bg-emerald-50 text-success")}>{notice.tone === "error" ? <AlertTriangle className="size-4 shrink-0" /> : <CheckCircle2 className="size-4 shrink-0" />}{notice.text}</div>}

    <section className="mt-6 grid gap-4 sm:grid-cols-3">
      {[{ label: "Actieve leden", value: counts.total }, { label: "Met bestelling", value: counts.ordered }, { label: "Betaald", value: counts.paid }].map((metric) => <div key={metric.label} className="rounded-xl border border-line bg-white px-5 py-4 shadow-card"><p className="text-[10px] font-bold uppercase tracking-[0.1em] text-slate-400">{metric.label}</p><p className="mt-2 text-2xl font-bold text-brand-900">{metric.value.toLocaleString("nl-NL")}</p></div>)}
    </section>

    <TeamArticleBulkPanel
      teams={workspace.teamOptions}
      articles={workspace.activeSeason ? workspace.articles.filter((article) => article.active && article.seasonIds.includes(workspace.activeSeason!.id)).map((article) => ({ ...article, variants: article.variants.filter((variant) => variant.active) })).filter((article) => article.variants.length > 0) : []}
      disabled={!workspace.activeSeason}
    />

    <div className="mt-6 grid items-start gap-6 xl:grid-cols-[390px_minmax(0,1fr)]">
      <aside className="overflow-hidden rounded-xl border border-line bg-white shadow-card">
        <div className="border-b border-line p-5"><h2 className="text-sm font-bold text-brand-900">Actieve leden</h2><label className="relative mt-4 block"><span className="sr-only">Zoek lid</span><Search className="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" /><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Naam, team of relatienummer" className="h-10 w-full rounded-lg border border-line pl-9 pr-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></label></div>
        {filteredMembers.length === 0 ? <div className="px-6 py-16 text-center"><CircleOff className="mx-auto size-8 text-slate-300" /><p className="mt-4 text-sm font-semibold text-slate-600">Geen leden gevonden</p><p className="mt-1 text-xs text-slate-400">Pas de zoekterm aan.</p></div> : <div className="max-h-[680px] divide-y divide-line overflow-y-auto">{filteredMembers.map((member) => <button key={member.id} type="button" onClick={() => chooseMember(member)} className={"flex w-full items-center gap-3 px-5 py-4 text-left transition " + (memberId === member.id ? "bg-brand-50" : "hover:bg-slate-50")}><span className="flex size-9 shrink-0 items-center justify-center rounded-full bg-brand-50 text-brand-700"><UsersRound className="size-4" /></span><span className="min-w-0 flex-1"><span className="block truncate text-xs font-bold text-ink">{member.name}</span><span className="mt-1 block truncate text-[10px] text-slate-400">{member.relationNumber} · {member.team}</span></span><span className={"rounded-full px-2 py-1 text-[9px] font-bold " + (member.order?.paid ? "bg-emerald-50 text-success" : member.order ? "bg-amber-50 text-amber-700" : "bg-slate-100 text-slate-500")}>{member.order?.paid ? "Betaald" : member.order ? "Open" : "Geen order"}</span></button>)}</div>}
      </aside>

      {!selected ? <section className="rounded-xl border border-brand-100 bg-brand-50 px-8 py-20 text-center"><ClipboardList className="mx-auto size-9 text-brand-400" /><h2 className="mt-5 text-base font-bold text-brand-900">Selecteer een lid</h2><p className="mx-auto mt-2 max-w-md text-xs leading-5 text-brand-700">Open een actief lid om de huidige seizoensbestelling te bekijken of veilig aan te maken.</p></section> : <OrderEditor member={selected} articles={editableArticles} activeSeason={workspace.activeSeason} amount={amount} lines={lines} saving={saving} onAmount={setAmount} onVariant={updateLine} onQuantity={updateQuantity} onSubmit={submit} />}
    </div>
  </div>;
}

function OrderEditor({ member, articles, activeSeason, amount, lines, saving, onAmount, onVariant, onQuantity, onSubmit }: {
  member: Member;
  articles: Article[];
  activeSeason: Workspace["activeSeason"];
  amount: string;
  lines: DraftLine[];
  saving: boolean;
  onAmount: (value: string) => void;
  onVariant: (articleId: string, variantId: string) => void;
  onQuantity: (articleId: string, quantity: number) => void;
  onSubmit: (event: FormEvent) => void;
}) {
  const readOnly = Boolean(member.order?.paid);
  return <form onSubmit={onSubmit} className="overflow-hidden rounded-xl border border-line bg-white shadow-card">
    <div className="flex flex-col gap-4 border-b border-line px-6 py-5 sm:flex-row sm:items-start sm:justify-between"><div><p className="text-[10px] font-bold uppercase tracking-[0.12em] text-brand-500">{activeSeason?.name ?? "Geen actief seizoen"}</p><h2 className="mt-1 text-lg font-bold text-brand-900">{member.name}</h2><p className="mt-1 text-xs text-slate-500">{member.relationNumber} · {member.team}</p></div><span className={"inline-flex h-8 items-center gap-2 self-start rounded-full px-3 text-[10px] font-bold " + (readOnly ? "bg-emerald-50 text-success" : "bg-amber-50 text-amber-700")}>{readOnly ? <LockKeyhole className="size-3.5" /> : <ClipboardList className="size-3.5" />}{readOnly ? "Betaald · alleen-lezen" : member.order ? "Open bestelling" : "Nieuwe bestelling"}</span></div>

    {readOnly && <div className="border-b border-brand-100 bg-brand-50 px-6 py-4 text-xs leading-5 text-brand-800">Deze bestelling is definitief betaald. Bedrag, maat en aantallen kunnen hier niet meer worden gewijzigd.</div>}

    <fieldset disabled={readOnly || !activeSeason || saving} className="p-6">
      <div className="max-w-sm"><label className="text-xs font-semibold text-ink">Exact verschuldigd bedrag<span className="mt-1 block text-[10px] font-normal leading-4 text-slate-400">Eén totaalbedrag voor deze bestelling; geen artikelprijzen of deelbedragen.</span><span className="relative mt-2 block"><span className="absolute left-3 top-1/2 -translate-y-1/2 text-sm font-semibold text-slate-500">€</span><input value={amount} onChange={(event) => onAmount(event.target.value)} required inputMode="decimal" aria-describedby="amount-help" className={fieldClass + " pl-8"} /></span></label><p id="amount-help" className="mt-2 text-[10px] text-slate-400">Gebruik maximaal twee decimalen, bijvoorbeeld 87,50.</p></div>

      <div className="mt-7 border-t border-line pt-6"><div className="flex items-end justify-between gap-4"><div><h3 className="text-sm font-bold text-brand-900">Artikelregels</h3><p className="mt-1 text-xs text-slate-500">Selecteer per artikel maximaal één variant en geef het aantal expliciet op.</p></div><span className="text-[10px] font-semibold text-slate-400">{lines.length} geselecteerd</span></div>
        {articles.length === 0 ? <div className="mt-5 rounded-lg border border-dashed border-line px-6 py-10 text-center"><Shirt className="mx-auto size-7 text-slate-300" /><p className="mt-3 text-xs font-semibold text-slate-500">Geen actieve artikelvarianten</p><p className="mt-1 text-[10px] text-slate-400">Activeer eerst artikelen en maten in de catalogus.</p></div> : <div className="mt-5 space-y-3">{articles.map((article) => {
          const line = lines.find((item) => item.articleId === article.id);
          const existingVariantId = member.order?.lines.find((item) => item.articleId === article.id)?.variantId;
          const options = article.variants.filter((variant) => variant.active || variant.id === existingVariantId);
          const existingStatus = member.order?.lines.find((item) => item.articleId === article.id)?.status;
          return <div key={article.id} className={"grid gap-3 rounded-xl border p-4 sm:grid-cols-[minmax(130px,0.7fr)_minmax(180px,1fr)_100px] sm:items-end " + (line ? "border-brand-100 bg-brand-50/40" : "border-line")}><div><p className="text-xs font-bold text-brand-900">{article.name}</p><p className="mt-1 text-[10px] text-slate-400">{article.code}{existingStatus ? " · " + lineStatusLabels[existingStatus] : ""}</p></div><label className="text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400">Maat<select value={line?.variantId ?? ""} onChange={(event) => onVariant(article.id, event.target.value)} className={"mt-2 " + fieldClass}><option value="">Niet opnemen</option>{options.map((variant) => <option key={variant.id} value={variant.id}>{variant.size}{variant.supplierCode ? " · " + variant.supplierCode : ""}{!variant.active ? " · inactief" : ""}</option>)}</select></label><label className="text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400">Aantal<input type="number" value={line?.quantity ?? 1} onChange={(event) => onQuantity(article.id, Number(event.target.value))} min={1} max={25} disabled={!line || readOnly} className={"mt-2 " + fieldClass} /></label></div>;
        })}</div>}
      </div>
    </fieldset>

    <div className="flex flex-col gap-3 border-t border-line bg-slate-50/60 px-6 py-4 sm:flex-row sm:items-center sm:justify-between"><p className="text-[10px] leading-4 text-slate-400">{readOnly ? "Historische en financiële gegevens blijven ongewijzigd." : "Opslaan valideert lid, seizoen, bedrag en varianten opnieuw op de server."}</p><button type="submit" disabled={readOnly || !activeSeason || saving || articles.length === 0} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:opacity-50">{saving ? <Loader2 className="size-4 animate-spin" /> : <CheckCircle2 className="size-4" />}{member.order ? "Bestelling opslaan" : "Bestelling aanmaken"}</button></div>
  </form>;
}
