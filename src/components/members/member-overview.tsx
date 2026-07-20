import { ArrowLeft, ArrowRight, ChevronRight, CircleOff, UsersRound } from "lucide-react";
import Link from "next/link";
import { ImportPanel } from "@/components/backoffice/import-panel";
import { StatusBadge } from "@/components/dashboard/status-badge";
import { MemberDetailPanel } from "@/components/members/member-detail-panel";
import { MemberFilterForm } from "@/components/members/member-filter-form";
import { TeamMemberStatusPanel } from "@/components/members/team-member-status-panel";
import type { MemberDetailResponse, MemberListQuery, MemberListResponse } from "@/lib/member-overview-contract";
import { cn } from "@/lib/utils";
import { MEMBER_LIST_PAGE_SIZE } from "@/server/members/overview";

function hrefFor(query: MemberListQuery, overrides: Partial<Record<keyof MemberListQuery, string | number | undefined>>) {
  const values = { ...query, ...overrides };
  const params = new URLSearchParams();
  for (const key of ["search", "team", "payment", "orderStatus", "articleId", "size", "lineStatus", "member"] as const) {
    const value = values[key];
    if (value) params.set(key, String(value));
  }
  if (values.page && Number(values.page) > 1) params.set("page", String(values.page));
  const suffix = params.toString();
  return suffix ? `/backoffice/leden?${suffix}` : "/backoffice/leden";
}

function euro(cents: number) {
  return new Intl.NumberFormat("nl-NL", { style: "currency", currency: "EUR" }).format(cents / 100);
}

export function MemberOverview({ list, detail, query }: {
  list: MemberListResponse;
  detail: MemberDetailResponse | null;
  query: MemberListQuery;
}) {
  const firstResult = list.filteredCount === 0 ? 0 : (query.page - 1) * MEMBER_LIST_PAGE_SIZE + 1;
  const lastResult = Math.min(query.page * MEMBER_LIST_PAGE_SIZE, list.filteredCount);
  const hasPrevious = query.page > 1;
  const hasNext = query.page * MEMBER_LIST_PAGE_SIZE < list.filteredCount;
  const closeDetailHref = hrefFor(query, { member: undefined });

  return (
    <div className="mx-auto max-w-[1440px]">
      <div>
        <p className="text-xs font-semibold uppercase tracking-[0.12em] text-brand-500">Ledenbeheer</p>
        <h1 className="mt-2 text-[30px] font-bold tracking-[-0.04em] text-brand-900 md:text-[34px]">Leden</h1>
        <p className="mt-2 text-sm text-slate-500">Zoek, filter en controleer leden met hun huidige bestelling en koppelingen.</p>
      </div>

      {!list.activeSeason && <section className="mt-7 rounded-xl border border-amber-200 bg-amber-50 p-5"><h2 className="text-sm font-bold text-amber-900">Geen actief seizoen</h2><p className="mt-1 text-xs leading-5 text-amber-800">Leden blijven doorzoekbaar, maar actuele bestellingen en seizoensstatussen zijn pas beschikbaar nadat een seizoen is geactiveerd.</p></section>}

      <div className={cn("mt-8 grid items-start gap-6", detail ? "xl:grid-cols-[minmax(0,1fr)_390px]" : "xl:grid-cols-[minmax(0,1fr)_340px]")}>
        <section className="min-w-0 overflow-hidden rounded-xl border border-line bg-white shadow-card">
          <div className="flex flex-col gap-3 border-b border-line px-5 py-5 sm:flex-row sm:items-center sm:justify-between">
            <div><h2 className="text-base font-bold text-brand-900">Ledenoverzicht</h2><p className="mt-1 text-xs text-slate-500">{list.activeCount.toLocaleString("nl-NL")} actief · {list.totalCount.toLocaleString("nl-NL")} totaal{list.activeSeason ? ` · seizoen ${list.activeSeason.name}` : ""}</p></div>
            <div className="rounded-lg bg-brand-50 px-3 py-2 text-xs font-semibold text-brand-700">{list.filteredCount.toLocaleString("nl-NL")} resultaten</div>
          </div>

          <MemberFilterForm query={query} options={list.filterOptions} />

          {list.members.length === 0 ? <div className="px-5 py-20 text-center"><CircleOff className="mx-auto size-8 text-slate-300" /><p className="mt-4 text-sm font-semibold text-slate-600">Geen leden gevonden</p><p className="mx-auto mt-1 max-w-sm text-xs leading-5 text-slate-400">Pas de zoekterm of filters aan. Een lege import verwijdert bestaande leden nooit.</p><Link href="/backoffice/leden" className="mt-4 inline-flex h-9 items-center justify-center rounded-lg border border-line px-3 text-xs font-semibold text-brand-700 hover:border-brand-500">Alle filters wissen</Link></div> : <div className="overflow-x-auto">
            <table className="w-full min-w-[860px] text-left">
              <thead><tr className="border-b border-line bg-slate-50/70 text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400"><th className="px-5 py-3">Lid</th><th className="px-3 py-3">Team</th><th className="px-3 py-3">Betaling</th><th className="px-3 py-3">Bestelstatus</th><th className="px-3 py-3">Bedrag</th><th className="px-3 py-3">Beschikbaar</th><th className="px-3 py-3"><span className="sr-only">Open detail</span></th></tr></thead>
              <tbody className="divide-y divide-line">{list.members.map((member) => {
                const selected = detail?.id === member.id;
                const progress = member.order && member.order.totalQuantity > 0 ? Math.min(100, (member.order.progressQuantity / member.order.totalQuantity) * 100) : 0;
                const detailHref = hrefFor(query, { member: member.id });
                return <tr key={member.id} className={cn("transition-colors hover:bg-brand-50/40", selected && "bg-brand-50/70")}>
                  <td className="px-5 py-3.5"><Link href={detailHref} className="group block"><div className="flex items-center gap-3"><div className="flex size-8 items-center justify-center rounded-full bg-brand-50 text-brand-700"><UsersRound className="size-4" /></div><div><p className="text-xs font-semibold text-ink group-hover:text-brand-700">{member.memberName}</p><p className="mt-0.5 text-[10px] text-slate-400">{member.relationNumber}{!member.activeForSeason && " · Inactief"}</p></div></div></Link></td>
                  <td className="px-3 py-3.5 text-xs text-slate-600">{member.team}</td>
                  <td className="px-3 py-3.5">{member.order ? <StatusBadge label={member.order.paymentStatus} /> : <span className="text-[11px] font-semibold text-slate-400">Geen bestelling</span>}</td>
                  <td className="px-3 py-3.5">{member.order ? <StatusBadge label={member.order.orderStatus} /> : <span className="text-[11px] text-slate-400">—</span>}</td>
                  <td className="px-3 py-3.5 text-xs font-semibold text-ink">{member.order ? euro(member.order.amountDueCents) : "—"}</td>
                  <td className="px-3 py-3.5">{member.order ? <div className="flex items-center gap-2"><div className="h-1.5 w-14 overflow-hidden rounded-full bg-slate-100"><div className="h-full rounded-full bg-brand-500" style={{ width: `${progress}%` }} /></div><span className="text-[11px] text-slate-500">{member.order.progressQuantity} van {member.order.totalQuantity}</span></div> : <span className="text-[11px] text-slate-400">—</span>}</td>
                  <td className="px-3 py-3.5 text-right"><Link href={detailHref} aria-label={`Open detail van ${member.memberName}`} className="inline-flex size-8 items-center justify-center rounded-lg text-slate-300 hover:bg-white hover:text-brand-700"><ChevronRight className="size-4" /></Link></td>
                </tr>;
              })}</tbody>
            </table>
          </div>}

          <div className="flex flex-col gap-3 border-t border-line px-5 py-4 sm:flex-row sm:items-center sm:justify-between">
            <p className="text-[11px] text-slate-400">{firstResult}–{lastResult} van {list.filteredCount.toLocaleString("nl-NL")} resultaten</p>
            <nav className="flex gap-2" aria-label="Paginering">
              {hasPrevious ? <Link href={hrefFor(query, { page: query.page - 1, member: undefined })} className="inline-flex h-9 items-center gap-2 rounded-lg border border-line px-3 text-xs font-semibold text-slate-600 hover:border-brand-500"><ArrowLeft className="size-3.5" /> Vorige</Link> : <span className="inline-flex h-9 items-center gap-2 rounded-lg border border-line px-3 text-xs font-semibold text-slate-300"><ArrowLeft className="size-3.5" /> Vorige</span>}
              {hasNext ? <Link href={hrefFor(query, { page: query.page + 1, member: undefined })} className="inline-flex h-9 items-center gap-2 rounded-lg border border-line px-3 text-xs font-semibold text-slate-600 hover:border-brand-500">Volgende <ArrowRight className="size-3.5" /></Link> : <span className="inline-flex h-9 items-center gap-2 rounded-lg border border-line px-3 text-xs font-semibold text-slate-300">Volgende <ArrowRight className="size-3.5" /></span>}
            </nav>
          </div>
        </section>

        <div className="space-y-6">
          {detail ? <MemberDetailPanel detail={detail} closeHref={closeDetailHref} /> : <section className="rounded-xl border border-brand-100 bg-brand-50 p-5"><h2 className="text-sm font-bold text-brand-900">Selecteer een lid</h2><p className="mt-1 text-xs leading-5 text-brand-700">Open een rij voor bedrag, betaling, artikelregels, QR-status, ouderkoppelingen en relevante historie.</p></section>}
          <TeamMemberStatusPanel teams={list.filterOptions.teams} initialTeam={query.team} disabled={!list.activeSeason} />
          <ImportPanel />
        </div>
      </div>
    </div>
  );
}
