import { Filter, Search } from "lucide-react";
import Link from "next/link";
import { MemberSavedViews } from "@/components/members/member-saved-views";
import {
  memberSavedViewFiltersFromQuery,
  type MemberListQuery,
  type MemberListResponse,
  type MemberSavedViewsResponse,
} from "@/lib/member-overview-contract";

const orderStatuses = [
  "Nog niet betaald",
  "Nalevering",
  "Gedeeltelijk af te halen",
  "Volledig af te halen",
  "Gedeeltelijk afgehaald",
  "Afgerond",
] as const;

export function MemberFilterForm({ query, options, savedViews }: {
  query: MemberListQuery;
  options: MemberListResponse["filterOptions"];
  savedViews: MemberSavedViewsResponse | null;
}) {
  const activeFilterCount = [
    query.team,
    query.payment,
    query.orderStatus,
    query.articleId,
    query.size,
    query.lineStatus,
  ].filter(Boolean).length;

  return (
    <>
      {savedViews && (
        <MemberSavedViews
          workspace={savedViews}
          currentFilters={memberSavedViewFiltersFromQuery(query)}
        />
      )}
      <form method="get" className="border-b border-line bg-slate-50/40 px-5 py-4">
      <div className="grid gap-3 lg:grid-cols-[minmax(220px,1fr)_repeat(3,minmax(130px,0.45fr))]">
        <label className="relative">
          <span className="sr-only">Zoek naam, team of relatienummer</span>
          <Search className="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" />
          <input name="search" defaultValue={query.search} placeholder="Zoek naam, team of relatienummer" className="h-10 w-full rounded-lg border border-line bg-white pl-9 pr-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" />
        </label>
        <label><span className="sr-only">Team</span><select name="team" defaultValue={query.team ?? ""} className="h-10 w-full rounded-lg border border-line bg-white px-3 text-xs text-slate-600 outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100"><option value="">Alle teams</option>{options.teams.map((team) => <option key={team} value={team}>{team}</option>)}</select></label>
        <label><span className="sr-only">Betaalstatus</span><select name="payment" defaultValue={query.payment ?? ""} className="h-10 w-full rounded-lg border border-line bg-white px-3 text-xs text-slate-600 outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100"><option value="">Alle betalingen</option><option value="paid">Betaald</option><option value="unpaid">Nog te betalen</option><option value="review">Controle vereist</option><option value="no_order">Geen bestelling</option></select></label>
        <label><span className="sr-only">Bestelstatus</span><select name="orderStatus" defaultValue={query.orderStatus ?? ""} className="h-10 w-full rounded-lg border border-line bg-white px-3 text-xs text-slate-600 outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100"><option value="">Alle bestelstatussen</option>{orderStatuses.map((status) => <option key={status} value={status}>{status}</option>)}</select></label>
      </div>
      <details className="mt-3" open={Boolean(query.articleId || query.size || query.lineStatus)}>
        <summary className="cursor-pointer text-xs font-semibold text-brand-700">Artikel- en uitgiftefilters {activeFilterCount > 0 && <span className="ml-1 rounded bg-brand-50 px-1.5 py-0.5 text-[10px]">{activeFilterCount} actief</span>}</summary>
        <div className="mt-3 grid gap-3 sm:grid-cols-3">
          <label><span className="sr-only">Artikel</span><select name="articleId" defaultValue={query.articleId ?? ""} className="h-10 w-full rounded-lg border border-line bg-white px-3 text-xs text-slate-600 outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100"><option value="">Alle artikelen</option>{options.articles.map((article) => <option key={article.id} value={article.id}>{article.name}</option>)}</select></label>
          <label><span className="sr-only">Maat</span><select name="size" defaultValue={query.size ?? ""} className="h-10 w-full rounded-lg border border-line bg-white px-3 text-xs text-slate-600 outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100"><option value="">Alle maten</option>{options.sizes.map((size) => <option key={size} value={size}>{size}</option>)}</select></label>
          <label><span className="sr-only">Uitgiftestatus</span><select name="lineStatus" defaultValue={query.lineStatus ?? ""} className="h-10 w-full rounded-lg border border-line bg-white px-3 text-xs text-slate-600 outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100"><option value="">Alle uitgiftestatussen</option><option value="backorder">Nalevering</option><option value="ready_for_pickup">Af te halen</option><option value="picked_up">Afgehaald</option><option value="cancelled">Geannuleerd</option></select></label>
        </div>
      </details>
      <div className="mt-4 flex flex-wrap items-center justify-between gap-3">
        <p className="text-[11px] text-slate-400">Filters worden server-side toegepast op het actieve seizoen.</p>
        <div className="flex gap-2">
          <Link href="/backoffice/leden" className="inline-flex h-9 items-center justify-center rounded-lg border border-line bg-white px-3 text-xs font-semibold text-slate-600 hover:border-brand-500">Wissen</Link>
          <button className="inline-flex h-9 items-center justify-center gap-2 rounded-lg bg-brand-700 px-3.5 text-xs font-semibold text-white hover:bg-brand-900"><Filter className="size-3.5" /> Filters toepassen</button>
        </div>
      </div>
      </form>
    </>
  );
}
