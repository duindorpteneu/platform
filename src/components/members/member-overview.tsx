import { ArrowLeft, ArrowRight } from "lucide-react";
import Link from "next/link";
import { ImportPanel } from "@/components/backoffice/import-panel";
import { MemberDetailPanel } from "@/components/members/member-detail-panel";
import { MemberFilterForm } from "@/components/members/member-filter-form";
import { MemberSelectionTable } from "@/components/members/member-selection-table";
import { ManualMemberPanel } from "@/components/members/manual-member-panel";
import { TeamMemberStatusPanel } from "@/components/members/team-member-status-panel";
import type {
  MemberDetailResponse,
  MemberListQuery,
  MemberListResponse,
  MemberSavedViewsResponse,
} from "@/lib/member-overview-contract";
import type { MemberPackageBulkOptions } from "@/lib/member-package-bulk-contract";
import type { ParentOtpSupport } from "@/lib/parent-otp-support-contract";
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

export function MemberOverview({ list, detail, otpSupport, query, savedViews, staffRole, packageOptions }: {
  list: MemberListResponse;
  detail: MemberDetailResponse | null;
  otpSupport: ParentOtpSupport | null;
  query: MemberListQuery;
  savedViews: MemberSavedViewsResponse | null;
  staffRole?: "beheerder" | "kledingcommissie" | "uitgifte";
  packageOptions: MemberPackageBulkOptions | null;
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

          <MemberFilterForm query={query} options={list.filterOptions} savedViews={savedViews} />

          <MemberSelectionTable
            members={list.members}
            query={query}
            selectedMemberId={detail?.id ?? null}
            seasonId={list.activeSeason?.id ?? null}
            staffRole={staffRole ?? "kledingcommissie"}
            activeCount={list.activeCount}
            packageOptions={packageOptions}
          />

          <div className="flex flex-col gap-3 border-t border-line px-5 py-4 sm:flex-row sm:items-center sm:justify-between">
            <p className="text-[11px] text-slate-400">{firstResult}–{lastResult} van {list.filteredCount.toLocaleString("nl-NL")} resultaten</p>
            <nav className="flex gap-2" aria-label="Paginering">
              {hasPrevious ? <Link href={hrefFor(query, { page: query.page - 1, member: undefined })} className="inline-flex h-9 items-center gap-2 rounded-lg border border-line px-3 text-xs font-semibold text-slate-600 hover:border-brand-500"><ArrowLeft className="size-3.5" /> Vorige</Link> : <button type="button" disabled className="inline-flex h-9 items-center gap-2 rounded-lg border border-line px-3 text-xs font-semibold text-slate-300"><ArrowLeft className="size-3.5" /> Vorige</button>}
              {hasNext ? <Link href={hrefFor(query, { page: query.page + 1, member: undefined })} className="inline-flex h-9 items-center gap-2 rounded-lg border border-line px-3 text-xs font-semibold text-slate-600 hover:border-brand-500">Volgende <ArrowRight className="size-3.5" /></Link> : <button type="button" disabled className="inline-flex h-9 items-center gap-2 rounded-lg border border-line px-3 text-xs font-semibold text-slate-300">Volgende <ArrowRight className="size-3.5" /></button>}
            </nav>
          </div>
        </section>

        <div className="space-y-6">
          {detail ? <MemberDetailPanel detail={detail} otpSupport={otpSupport} closeHref={closeDetailHref} staffRole={staffRole} /> : <section className="rounded-xl border border-brand-100 bg-brand-50 p-5"><h2 className="text-sm font-bold text-brand-900">Selecteer een lid</h2><p className="mt-1 text-xs leading-5 text-brand-700">Open een rij voor bedrag, betaling, artikelregels, QR-status, ouderkoppelingen en relevante historie.</p></section>}
          <TeamMemberStatusPanel teams={list.filterOptions.teams} initialTeam={query.team} disabled={!list.activeSeason} />
          {staffRole === "beheerder" && <ManualMemberPanel />}
          {staffRole === "beheerder" && <ImportPanel />}
        </div>
      </div>
    </div>
  );
}
