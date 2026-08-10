"use client";

import {
  CheckSquare2,
  ChevronRight,
  CircleOff,
  KeyRound,
  Mail,
  Square,
  UsersRound,
  X,
} from "lucide-react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useMemo, useState } from "react";
import { StatusBadge } from "@/components/dashboard/status-badge";
import {
  MEMBER_BULK_CONTEXT_STORAGE_KEY,
  MEMBER_BULK_CONTEXT_TTL_MS,
  memberBulkContextSchema,
  type MemberBulkContext,
} from "@/lib/member-bulk-contract";
import type {
  MemberListQuery,
  MemberListResponse,
} from "@/lib/member-overview-contract";
import { cn } from "@/lib/utils";

type MemberRow = MemberListResponse["members"][number];

function memberHref(
  query: MemberListQuery,
  overrides: Partial<Record<keyof MemberListQuery, string | number | undefined>>,
) {
  const values = { ...query, ...overrides };
  const params = new URLSearchParams();
  for (const key of [
    "search",
    "team",
    "payment",
    "orderStatus",
    "articleId",
    "size",
    "lineStatus",
    "member",
  ] as const) {
    const value = values[key];
    if (value) params.set(key, String(value));
  }
  if (values.page && Number(values.page) > 1) {
    params.set("page", String(values.page));
  }
  const suffix = params.toString();
  return suffix ? `/backoffice/leden?${suffix}` : "/backoffice/leden";
}

function euro(cents: number) {
  return new Intl.NumberFormat("nl-NL", {
    style: "currency",
    currency: "EUR",
  }).format(cents / 100);
}

export function MemberSelectionTable({
  members,
  query,
  selectedMemberId,
  seasonId,
  staffRole,
}: {
  members: MemberRow[];
  query: MemberListQuery;
  selectedMemberId: string | null;
  seasonId: string | null;
  staffRole: "beheerder" | "kledingcommissie" | "uitgifte";
}) {
  const router = useRouter();
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const selected = useMemo(
    () => members.filter((member) => selectedIds.has(member.id)),
    [members, selectedIds],
  );
  const selectable = members.filter((member) => member.memberSeasonId !== null);
  const allVisibleSelected = selectable.length > 0
    && selectable.every((member) => selectedIds.has(member.id));
  const portalEligible = selected.filter((member) => (
    member.memberSeasonId
    && member.bulkEligibility.portalAccessPreflight
  ));
  const mailEligible = selected.filter((member) => (
    member.memberSeasonId
    && member.bulkEligibility.mailPreflight
  ));
  const teamEligible = selected.filter((member) => (
    member.memberSeasonId
    && member.bulkEligibility.teamStatusPreflight
  ));
  const commonTeam = teamEligible.length === selected.length
    && new Set(teamEligible.map((member) => member.team)).size === 1
    ? teamEligible[0]?.team ?? null
    : null;

  function toggle(member: MemberRow) {
    if (!member.memberSeasonId) return;
    setSelectedIds((current) => {
      const next = new Set(current);
      if (next.has(member.id)) next.delete(member.id);
      else next.add(member.id);
      return next;
    });
  }

  function toggleVisible() {
    setSelectedIds((current) => {
      const next = new Set(current);
      if (allVisibleSelected) {
        selectable.forEach((member) => next.delete(member.id));
      } else {
        selectable.forEach((member) => next.add(member.id));
      }
      return next;
    });
  }

  function routeWithContext(
    target: MemberBulkContext["target"],
    targetMembers: MemberRow[],
    path: string,
  ) {
    if (!seasonId) return;
    const now = Date.now();
    const context = memberBulkContextSchema.parse({
      version: 1,
      source: "member_overview",
      target,
      seasonId,
      createdAt: new Date(now).toISOString(),
      expiresAt: new Date(now + MEMBER_BULK_CONTEXT_TTL_MS).toISOString(),
      entries: targetMembers.flatMap((member) => (
        member.memberSeasonId
          ? [{
            memberId: member.id,
            memberSeasonId: member.memberSeasonId,
            orderId: member.order?.id ?? null,
            team: member.team,
          }]
          : []
      )),
    });
    window.sessionStorage.setItem(
      MEMBER_BULK_CONTEXT_STORAGE_KEY,
      JSON.stringify(context),
    );
    router.push(path);
  }

  if (members.length === 0) {
    return (
      <div className="px-5 py-20 text-center">
        <CircleOff className="mx-auto size-8 text-slate-300" />
        <p className="mt-4 text-sm font-semibold text-slate-600">
          Geen leden gevonden
        </p>
        <p className="mx-auto mt-1 max-w-sm text-xs leading-5 text-slate-500">
          Pas de zoekterm of filters aan. Een lege import verwijdert bestaande
          leden nooit.
        </p>
        <Link
          href="/backoffice/leden"
          className="mt-4 inline-flex h-9 items-center justify-center rounded-lg border border-line px-3 text-xs font-semibold text-brand-700 hover:border-brand-500"
        >
          Alle filters wissen
        </Link>
      </div>
    );
  }

  return (
    <>
      <div className="overflow-x-auto">
        <table className="w-full min-w-[930px] text-left">
          <thead>
            <tr className="border-b border-line bg-slate-50/70 text-xs font-bold uppercase tracking-[0.08em] text-slate-500">
              <th className="w-12 px-4 py-3">
                <button
                  type="button"
                  onClick={toggleVisible}
                  disabled={selectable.length === 0}
                  aria-label={allVisibleSelected
                    ? "Deselecteer alle zichtbare leden"
                    : "Selecteer alle zichtbare leden"}
                  className="inline-flex size-8 items-center justify-center rounded-lg text-brand-700 hover:bg-brand-50 disabled:text-slate-300"
                >
                  {allVisibleSelected
                    ? <CheckSquare2 className="size-4" />
                    : <Square className="size-4" />}
                </button>
              </th>
              <th className="px-3 py-3">Lid</th>
              <th className="px-3 py-3">Team</th>
              <th className="px-3 py-3">Betaling</th>
              <th className="px-3 py-3">Bestelstatus</th>
              <th className="px-3 py-3">Bedrag</th>
              <th className="px-3 py-3">Beschikbaar</th>
              <th className="px-3 py-3"><span className="sr-only">Open detail</span></th>
            </tr>
          </thead>
          <tbody className="divide-y divide-line">
            {members.map((member) => {
              const detailSelected = selectedMemberId === member.id;
              const checked = selectedIds.has(member.id);
              const progress = member.order && member.order.totalQuantity > 0
                ? Math.min(
                  100,
                  (member.order.progressQuantity / member.order.totalQuantity) * 100,
                )
                : 0;
              const detailHref = memberHref(query, { member: member.id });
              return (
                <tr
                  key={member.id}
                  className={cn(
                    "transition-colors hover:bg-brand-50/40",
                    detailSelected && "bg-brand-50/70",
                    checked && "bg-brand-50/50",
                  )}
                >
                  <td className="px-4 py-3.5">
                    <input
                      type="checkbox"
                      checked={checked}
                      disabled={!member.memberSeasonId}
                      onChange={() => toggle(member)}
                      aria-label={`Selecteer ${member.memberName}`}
                      className="size-4 rounded border-slate-300 text-brand-700 focus:ring-brand-500 disabled:opacity-40"
                    />
                  </td>
                  <td className="px-3 py-3.5">
                    <Link href={detailHref} className="group block">
                      <div className="flex items-center gap-3">
                        <div className="flex size-8 items-center justify-center rounded-full bg-brand-50 text-brand-700">
                          <UsersRound className="size-4" />
                        </div>
                        <div>
                          <p className="text-xs font-semibold text-ink group-hover:text-brand-700">
                            {member.memberName}
                          </p>
                          <p className="mt-0.5 text-xs text-slate-500">
                            {member.relationNumber ?? "Geen relatienummer"}
                            {!member.activeForSeason && " · Inactief"}
                          </p>
                        </div>
                      </div>
                    </Link>
                  </td>
                  <td className="px-3 py-3.5 text-xs text-slate-600">
                    {member.team}
                  </td>
                  <td className="px-3 py-3.5">
                    {member.order
                      ? <StatusBadge label={member.order.paymentStatus} />
                      : <span className="text-xs font-semibold text-slate-500">Geen bestelling</span>}
                  </td>
                  <td className="px-3 py-3.5">
                    {member.order
                      ? <StatusBadge label={member.order.orderStatus} />
                      : <span className="text-xs text-slate-500">—</span>}
                  </td>
                  <td className="px-3 py-3.5 text-xs font-semibold text-ink">
                    {member.order ? euro(member.order.amountDueCents) : "—"}
                  </td>
                  <td className="px-3 py-3.5">
                    {member.order ? (
                      <div className="flex items-center gap-2">
                        <div className="h-1.5 w-14 overflow-hidden rounded-full bg-slate-100">
                          <div
                            className="h-full rounded-full bg-brand-500"
                            style={{ width: `${progress}%` }}
                          />
                        </div>
                        <span className="text-xs text-slate-500">
                          {member.order.progressQuantity} van {member.order.totalQuantity}
                        </span>
                      </div>
                    ) : <span className="text-xs text-slate-500">—</span>}
                  </td>
                  <td className="px-3 py-3.5 text-right">
                    <Link
                      href={detailHref}
                      aria-label={`Open detail van ${member.memberName}`}
                      className="inline-flex size-8 items-center justify-center rounded-lg text-slate-300 hover:bg-white hover:text-brand-700"
                    >
                      <ChevronRight className="size-4" />
                    </Link>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      {selected.length > 0 && (
        <div className="sticky bottom-4 z-20 mx-4 my-4 flex flex-col gap-3 rounded-xl border border-brand-200 bg-brand-900 p-3 text-white shadow-xl lg:flex-row lg:items-center">
          <div className="flex min-w-48 items-center justify-between gap-3">
            <p className="text-xs font-bold">
              {selected.length} lid/leden geselecteerd
            </p>
            <button
              type="button"
              onClick={() => setSelectedIds(new Set())}
              className="inline-flex size-8 items-center justify-center rounded-lg text-brand-100 hover:bg-white/10"
              aria-label="Selectie wissen"
            >
              <X className="size-4" />
            </button>
          </div>
          <div className="flex flex-1 flex-wrap gap-2 lg:justify-end">
            {staffRole === "beheerder" && (
              <button
                type="button"
                disabled={portalEligible.length === 0}
                onClick={() => routeWithContext(
                  "portal_access",
                  portalEligible,
                  "/backoffice/portaaltoegang",
                )}
                className="inline-flex min-h-10 items-center gap-2 rounded-lg bg-white px-3 text-xs font-semibold text-brand-900 hover:bg-brand-50 disabled:cursor-not-allowed disabled:opacity-40"
              >
                <KeyRound className="size-4" />
                Portaaltoegang ({portalEligible.length})
              </button>
            )}
            <button
              type="button"
              disabled={mailEligible.length === 0}
              onClick={() => routeWithContext(
                "email",
                mailEligible,
                "/backoffice/emails?tab=bulk",
              )}
              className="inline-flex min-h-10 items-center gap-2 rounded-lg bg-white px-3 text-xs font-semibold text-brand-900 hover:bg-brand-50 disabled:cursor-not-allowed disabled:opacity-40"
            >
              <Mail className="size-4" />
              E-mailpreflight ({mailEligible.length})
            </button>
            <button
              type="button"
              disabled={!commonTeam}
              title={commonTeam
                ? `Opent de bestaande preflight voor het hele team ${commonTeam}`
                : "Selecteer uitsluitend leden uit hetzelfde team"}
              onClick={() => {
                if (!commonTeam) return;
                router.push(
                  `${memberHref(query, {
                    team: commonTeam,
                    member: undefined,
                    page: 1,
                  })}#team-status-panel`,
                );
              }}
              className="inline-flex min-h-10 items-center gap-2 rounded-lg border border-white/30 px-3 text-xs font-semibold text-white hover:bg-white/10 disabled:cursor-not-allowed disabled:opacity-40"
            >
              <UsersRound className="size-4" />
              Teamstatus · heel team
            </button>
          </div>
        </div>
      )}
    </>
  );
}
