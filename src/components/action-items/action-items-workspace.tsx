"use client";

import {
  CheckCircle2,
  CircleDot,
  Clock3,
  Loader2,
  Play,
  RefreshCw,
  UserRoundCheck,
  XCircle,
} from "lucide-react";
import Link from "next/link";
import { FormEvent, useMemo, useState } from "react";
import {
  actionItemMutationResponseSchema,
  actionItemTarget,
  actionItemWorkspaceSchema,
  type ActionItemWorkspaceData,
} from "@/lib/action-item-contract";
import { cn } from "@/lib/utils";

type ActionItem = ActionItemWorkspaceData["items"][number];
type CloseMode = "resolve" | "dismiss";

const statusLabels = {
  open: "Open",
  in_progress: "In behandeling",
  resolved: "Opgelost",
  dismissed: "Afgewezen",
};
const severityLabels = {
  info: "Info",
  warning: "Waarschuwing",
  critical: "Kritiek",
};
const typeLabels: Record<string, string> = {
  allocation_conflict: "Allocatieconflict",
  email_bounce: "E-mailbounce",
  email_failure: "Definitieve e-mailfout",
  low_stock: "Lage voorraad",
  mail_projection_suppressed: "Communicatie geblokkeerd",
  package_change_after_payment: "Pakketwijziging na betaling",
  payment_conflict: "Betaalconflict",
  paid_waiting_stock: "Betaald zonder voorraad",
  receipt_incomplete: "Onvolledige levering",
  size_change_after_reservation: "Maatwijziging na reservering",
  size_missing: "Maat ontbreekt",
  size_other: "Afwijkende maat",
  size_unconfirmed: "Maat niet bevestigd",
  stock_reconciliation_conflict: "Voorraadreconciliatie",
};
const contextLabels: Record<string, string> = {
  allocationId: "Allocatie",
  articleId: "Product",
  available: "Vrij beschikbaar",
  blocked: "Geblokkeerd",
  count: "Aantal",
  deliveryDraftId: "Leveringconcept",
  eligible: "Geschikt",
  episode: "Episode",
  fulfilmentId: "Uitgifte",
  memberSeasonId: "Lid-seizoen",
  orderItemId: "Pakketregel",
  packageOrderId: "Pakketorder",
  quantity: "Aantal",
  queueDepth: "Wachtrij",
  receiptId: "Ontvangst",
  requested: "Gevraagd",
  reserved: "Gereserveerd",
  shortage: "Tekort",
  sourceRow: "Bronrij",
  variantId: "Variant",
  waiterCount: "Wachtenden",
};

function formatDate(value: string | null) {
  if (!value) return "—";
  return new Intl.DateTimeFormat("nl-NL", {
    timeZone: "Europe/Amsterdam",
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(value));
}

function humanize(value: string) {
  return value
    .replaceAll("_", " ")
    .replace(/\b\w/g, (character) => character.toUpperCase());
}

function displayContextValue(value: string | number | boolean) {
  if (typeof value === "boolean") return value ? "Ja" : "Nee";
  if (typeof value === "number") return new Intl.NumberFormat("nl-NL").format(value);
  return `${value.slice(0, 8)}…`;
}

function privateHeaders() {
  return {
    "Content-Type": "application/json",
    "X-Duindorp-CSRF": "same-origin",
  };
}

export function ActionItemsWorkspace({
  initial,
}: {
  initial: ActionItemWorkspaceData;
}) {
  const [workspace, setWorkspace] = useState(initial);
  const [status, setStatus] = useState<"" | ActionItem["status"]>("");
  const [severity, setSeverity] = useState<"" | ActionItem["severity"]>("");
  const [ownerFilter, setOwnerFilter] = useState("");
  const [assignmentDrafts, setAssignmentDrafts] = useState<Record<string, string>>({});
  const [closeTarget, setCloseTarget] = useState<{
    itemId: string;
    mode: CloseMode;
  } | null>(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  const firstResult = workspace.total === 0 ? 0 : workspace.offset + 1;
  const lastResult = Math.min(
    workspace.offset + workspace.limit,
    workspace.total,
  );
  const counts = useMemo(() => [
    {
      label: "Open",
      value: workspace.statusCounts.open,
      icon: CircleDot,
      tone: "text-brand-700 bg-brand-50 border-brand-100",
    },
    {
      label: "In behandeling",
      value: workspace.statusCounts.inProgress,
      icon: Clock3,
      tone: "text-amber-800 bg-amber-50 border-amber-200",
    },
    {
      label: "Afgerond",
      value: workspace.statusCounts.resolved + workspace.statusCounts.dismissed,
      icon: CheckCircle2,
      tone: "text-emerald-700 bg-emerald-50 border-emerald-200",
    },
  ], [workspace]);

  async function query(
    offset: number,
    nextSeasonId = workspace.selectedSeason.id,
  ) {
    setBusy("query");
    setError(null);
    try {
      const response = await fetch("/api/action-items/query", {
        method: "POST",
        headers: privateHeaders(),
        cache: "no-store",
        body: JSON.stringify({
          seasonId: nextSeasonId,
          status: status || null,
          severity: severity || null,
          ownerUserId: ownerFilter && ownerFilter !== "__unassigned"
            ? ownerFilter
            : null,
          onlyUnassigned: ownerFilter === "__unassigned",
          offset,
          limit: 50,
        }),
      });
      const payload: unknown = await response.json();
      if (!response.ok) {
        throw new Error(
          typeof payload === "object" && payload && "error" in payload
            ? String(payload.error)
            : "De actiepunten konden niet worden geladen.",
        );
      }
      const parsed = actionItemWorkspaceSchema.safeParse(payload);
      if (!parsed.success) throw new Error("De actiepuntrespons is ongeldig.");
      setWorkspace(parsed.data);
      setAssignmentDrafts({});
      setCloseTarget(null);
      setReason("");
    } catch (queryError) {
      setError(
        queryError instanceof Error
          ? queryError.message
          : "De actiepunten konden niet worden geladen.",
      );
    } finally {
      setBusy(null);
    }
  }

  async function submitFilters(event: FormEvent) {
    event.preventDefault();
    await query(0);
  }

  async function mutate(
    endpoint: "assign" | "start" | "resolve" | "dismiss",
    item: ActionItem,
    extra: Record<string, unknown> = {},
  ) {
    setBusy(`${endpoint}:${item.id}`);
    setError(null);
    setSuccess(null);
    try {
      const response = await fetch(`/api/action-items/${endpoint}`, {
        method: "POST",
        headers: privateHeaders(),
        body: JSON.stringify({
          actionItemId: item.id,
          expectedRevision: item.revision,
          ...extra,
        }),
      });
      const payload: unknown = await response.json();
      if (!response.ok) {
        throw new Error(
          typeof payload === "object" && payload && "error" in payload
            ? String(payload.error)
            : "De actiepunthandeling is niet uitgevoerd.",
        );
      }
      const parsed = actionItemMutationResponseSchema.safeParse(payload);
      if (!parsed.success) throw new Error("De bevestigingsrespons is ongeldig.");
      setSuccess(endpoint === "assign"
        ? "De eigenaar is bijgewerkt."
        : endpoint === "start"
          ? "Het actiepunt is gestart."
          : endpoint === "resolve"
            ? "Het actiepunt is opgelost."
            : "Het actiepunt is gemotiveerd afgewezen.");
      await query(workspace.offset);
    } catch (mutationError) {
      setError(
        mutationError instanceof Error
          ? mutationError.message
          : "De actiepunthandeling is niet uitgevoerd.",
      );
    } finally {
      setBusy(null);
    }
  }

  function prepareClose(item: ActionItem, mode: CloseMode) {
    setCloseTarget({ itemId: item.id, mode });
    setReason("");
    setError(null);
    setSuccess(null);
  }

  async function submitClose(item: ActionItem) {
    if (!closeTarget || reason.trim().length < 3) {
      setError("Vul een reden van minimaal drie tekens in.");
      return;
    }
    await mutate(closeTarget.mode, item, { reason: reason.trim() });
  }

  return (
    <div className="mx-auto max-w-[1440px]">
      <header className="flex flex-col justify-between gap-4 lg:flex-row lg:items-end">
        <div>
          <p className="text-xs font-semibold uppercase tracking-[0.12em] text-brand-500">
            Operationele werkvoorraad
          </p>
          <h1 className="mt-2 text-[30px] font-bold tracking-[-0.04em] text-brand-900 md:text-[34px]">
            Actiepunten
          </h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">
            Behandel gededupliceerde signalen per seizoen. Actiepunten worden
            toegewezen, geaudit gesloten en nooit verwijderd.
          </p>
        </div>
        <button
          type="button"
          disabled={busy !== null}
          onClick={() => void query(workspace.offset)}
          className="inline-flex min-h-11 items-center justify-center gap-2 self-start rounded-lg border border-line bg-white px-4 text-xs font-semibold text-brand-700 shadow-sm hover:bg-slate-50 disabled:opacity-60"
        >
          <RefreshCw className={cn("size-4", busy === "query" && "animate-spin")} />
          Vernieuwen
        </button>
      </header>

      <section className="mt-7 grid gap-3 sm:grid-cols-3">
        {counts.map(({ label, value, icon: Icon, tone }) => (
          <div key={label} className={cn("rounded-xl border p-4", tone)}>
            <div className="flex items-center justify-between">
              <span className="text-xs font-bold uppercase tracking-[0.08em]">{label}</span>
              <Icon className="size-4" />
            </div>
            <p className="mt-2 text-2xl font-bold">{value}</p>
          </div>
        ))}
      </section>

      <form
        onSubmit={submitFilters}
        className="mt-5 grid gap-3 rounded-xl border border-line bg-white p-4 shadow-card md:grid-cols-2 xl:grid-cols-5 xl:items-end"
      >
        <label className="text-xs font-semibold text-slate-600">
          Seizoen
          <select
            value={workspace.selectedSeason.id}
            onChange={(event) => void query(0, event.target.value)}
            className="mt-1.5 h-11 w-full rounded-lg border border-line bg-white px-3 text-sm text-ink focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-100"
          >
            {workspace.seasons.map((season) => (
              <option key={season.id} value={season.id}>
                {season.name}{season.active ? " · actief" : ""}
              </option>
            ))}
          </select>
        </label>
        <label className="text-xs font-semibold text-slate-600">
          Status
          <select
            value={status}
            onChange={(event) => setStatus(event.target.value as typeof status)}
            className="mt-1.5 h-11 w-full rounded-lg border border-line bg-white px-3 text-sm text-ink focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-100"
          >
            <option value="">Alle statussen</option>
            {Object.entries(statusLabels).map(([value, label]) => (
              <option key={value} value={value}>{label}</option>
            ))}
          </select>
        </label>
        <label className="text-xs font-semibold text-slate-600">
          Ernst
          <select
            value={severity}
            onChange={(event) => setSeverity(event.target.value as typeof severity)}
            className="mt-1.5 h-11 w-full rounded-lg border border-line bg-white px-3 text-sm text-ink focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-100"
          >
            <option value="">Alle ernstniveaus</option>
            {Object.entries(severityLabels).map(([value, label]) => (
              <option key={value} value={value}>{label}</option>
            ))}
          </select>
        </label>
        <label className="text-xs font-semibold text-slate-600">
          Eigenaar
          <select
            value={ownerFilter}
            onChange={(event) => setOwnerFilter(event.target.value)}
            className="mt-1.5 h-11 w-full rounded-lg border border-line bg-white px-3 text-sm text-ink focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-100"
          >
            <option value="">Alle eigenaren</option>
            <option value="__unassigned">Niet toegewezen</option>
            {workspace.ownerOptions.map((owner) => (
              <option key={owner.userId} value={owner.userId}>
                {owner.displayName}
              </option>
            ))}
          </select>
        </label>
        <button
          disabled={busy !== null}
          className="inline-flex h-11 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 disabled:opacity-60"
        >
          {busy === "query" && <Loader2 className="size-4 animate-spin" />}
          Filters toepassen
        </button>
      </form>

      {(error || success) && (
        <div
          role={error ? "alert" : "status"}
          className={cn(
            "mt-4 rounded-lg border px-4 py-3 text-sm font-medium",
            error
              ? "border-red-200 bg-red-50 text-danger"
              : "border-emerald-200 bg-emerald-50 text-success",
          )}
        >
          {error ?? success}
        </div>
      )}

      <section className="mt-5 space-y-3" aria-label="Actiepuntenlijst">
        {workspace.items.length === 0 && (
          <div className="rounded-xl border border-dashed border-line bg-white px-6 py-12 text-center">
            <CheckCircle2 className="mx-auto size-8 text-emerald-500" />
            <h2 className="mt-3 text-base font-bold text-brand-900">Geen actiepunten</h2>
            <p className="mt-1 text-sm text-slate-500">
              Er zijn geen resultaten voor deze veilige seizoenfilters.
            </p>
          </div>
        )}
        {workspace.items.map((item) => {
          const itemBusy = busy?.endsWith(item.id);
          const closeOpen = closeTarget?.itemId === item.id;
          const ownerChoices = workspace.ownerOptions.filter(
            (owner) => item.visibility === "operations" || owner.role === "beheerder",
          );
          const contextEntries = Object.entries(item.safeContext);
          const target = actionItemTarget(item);
          return (
            <article
              key={item.id}
              className="rounded-xl border border-line bg-white p-4 shadow-card md:p-5"
            >
              <div className="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className={cn(
                      "rounded-full border px-2.5 py-1 text-xs font-bold",
                      item.severity === "critical"
                        ? "border-red-200 bg-red-50 text-danger"
                        : item.severity === "warning"
                          ? "border-amber-200 bg-amber-50 text-amber-800"
                          : "border-blue-200 bg-blue-50 text-brand-700",
                    )}>
                      {severityLabels[item.severity]}
                    </span>
                    <span className={cn(
                      "rounded-full px-2.5 py-1 text-xs font-semibold",
                      item.status === "resolved"
                        ? "bg-emerald-50 text-success"
                        : item.status === "dismissed"
                          ? "bg-slate-100 text-slate-600"
                          : item.status === "in_progress"
                            ? "bg-amber-50 text-amber-800"
                            : "bg-brand-50 text-brand-700",
                    )}>
                      {statusLabels[item.status]}
                    </span>
                    <span className="text-xs font-medium text-slate-500">
                      Episode {item.episode} · revisie {item.revision}
                    </span>
                  </div>
                  <h2 className="mt-3 text-lg font-bold text-brand-900">
                    {typeLabels[item.type] ?? humanize(item.type)}
                  </h2>
                  <p className="mt-1 text-xs text-slate-500">
                    Reden: {humanize(item.reasonCode)} · object {humanize(item.objectType)}
                    {" "}· bron {humanize(item.sourceType)}
                  </p>
                  {contextEntries.length > 0 && (
                    <dl className="mt-3 flex flex-wrap gap-2">
                      {contextEntries.map(([key, value]) => (
                        <div
                          key={key}
                          className="rounded-lg border border-line bg-slate-50 px-2.5 py-1.5 text-xs"
                        >
                          <dt className="inline font-semibold text-slate-500">
                            {contextLabels[key] ?? humanize(key)}:
                          </dt>{" "}
                          <dd className="inline text-ink">
                            {displayContextValue(value)}
                          </dd>
                        </div>
                      ))}
                    </dl>
                  )}
                  {item.status === "open" || item.status === "in_progress" ? (
                    <Link
                      href={target.href}
                      className="mt-3 inline-flex min-h-11 items-center rounded-lg border border-brand-200 bg-white px-3 text-xs font-semibold text-brand-700 hover:bg-brand-50"
                    >
                      {target.label}
                    </Link>
                  ) : null}
                </div>
                <dl className="grid shrink-0 grid-cols-2 gap-x-6 gap-y-2 text-xs xl:w-[370px]">
                  <div>
                    <dt className="text-slate-500">Eigenaar</dt>
                    <dd className="mt-0.5 font-semibold text-ink">
                      {item.ownerDisplayName ?? "Niet toegewezen"}
                    </dd>
                  </div>
                  <div>
                    <dt className="text-slate-500">SLA</dt>
                    <dd className="mt-0.5 font-semibold text-ink">{formatDate(item.dueAt)}</dd>
                  </div>
                  <div>
                    <dt className="text-slate-500">Geopend</dt>
                    <dd className="mt-0.5 text-ink">{formatDate(item.openedAt)}</dd>
                  </div>
                  <div>
                    <dt className="text-slate-500">Laatst gezien</dt>
                    <dd className="mt-0.5 text-ink">{formatDate(item.lastSeenAt)}</dd>
                  </div>
                </dl>
              </div>

              {item.actions.canAssign && (
                <div className="mt-5 flex flex-col gap-2 border-t border-line pt-4 sm:flex-row sm:items-end">
                  <label className="flex-1 text-xs font-semibold text-slate-600">
                    Eigenaar wijzigen
                    <select
                      value={assignmentDrafts[item.id] ?? item.ownerUserId ?? ""}
                      onChange={(event) => setAssignmentDrafts((current) => ({
                        ...current,
                        [item.id]: event.target.value,
                      }))}
                      className="mt-1.5 h-11 w-full rounded-lg border border-line bg-white px-3 text-sm text-ink focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-100"
                    >
                      {item.status === "open" && <option value="">Niet toegewezen</option>}
                      {ownerChoices.map((owner) => (
                        <option key={owner.userId} value={owner.userId}>
                          {owner.displayName} · {owner.role === "beheerder" ? "beheerder" : "kledingcommissie"}
                        </option>
                      ))}
                    </select>
                  </label>
                  <button
                    type="button"
                    disabled={busy !== null}
                    onClick={() => void mutate("assign", item, {
                      ownerUserId: (assignmentDrafts[item.id] ?? item.ownerUserId ?? "") || null,
                    })}
                    className="inline-flex h-11 items-center justify-center gap-2 rounded-lg border border-line bg-white px-4 text-xs font-semibold text-brand-700 hover:bg-slate-50 disabled:opacity-60"
                  >
                    <UserRoundCheck className="size-4" />
                    Toewijzen
                  </button>
                  {item.actions.canStart && (
                    <button
                      type="button"
                      disabled={busy !== null}
                      onClick={() => void mutate("start", item)}
                      className="inline-flex h-11 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 disabled:opacity-60"
                    >
                      <Play className="size-4" />
                      Starten
                    </button>
                  )}
                  {item.actions.canResolve && (
                    <button
                      type="button"
                      disabled={busy !== null}
                      onClick={() => prepareClose(item, "resolve")}
                      className="inline-flex h-11 items-center justify-center gap-2 rounded-lg bg-emerald-600 px-4 text-xs font-semibold text-white hover:bg-emerald-700 disabled:opacity-60"
                    >
                      <CheckCircle2 className="size-4" />
                      Oplossen
                    </button>
                  )}
                  {item.actions.canDismiss && (
                    <button
                      type="button"
                      disabled={busy !== null}
                      onClick={() => prepareClose(item, "dismiss")}
                      className="inline-flex h-11 items-center justify-center gap-2 rounded-lg border border-red-200 bg-white px-4 text-xs font-semibold text-danger hover:bg-red-50 disabled:opacity-60"
                    >
                      <XCircle className="size-4" />
                      Afwijzen
                    </button>
                  )}
                </div>
              )}

              {closeOpen && (
                <div className="mt-4 rounded-lg border border-line bg-slate-50 p-4">
                  <label className="text-xs font-semibold text-slate-700">
                    {closeTarget.mode === "resolve" ? "Oplossing" : "Afwijsreden"}
                    <textarea
                      autoFocus
                      value={reason}
                      onChange={(event) => setReason(event.target.value)}
                      minLength={3}
                      maxLength={500}
                      rows={3}
                      className="mt-1.5 w-full rounded-lg border border-line bg-white p-3 text-sm text-ink focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-100"
                      placeholder={closeTarget.mode === "resolve"
                        ? "Beschrijf kort wat aantoonbaar is hersteld."
                        : "Leg vast waarom dit actiepunt bewust wordt afgewezen."}
                    />
                  </label>
                  <div className="mt-3 flex flex-wrap justify-end gap-2">
                    <button
                      type="button"
                      onClick={() => {
                        setCloseTarget(null);
                        setReason("");
                      }}
                      className="min-h-11 rounded-lg border border-line bg-white px-4 text-xs font-semibold text-slate-600"
                    >
                      Annuleren
                    </button>
                    <button
                      type="button"
                      disabled={Boolean(itemBusy) || reason.trim().length < 3}
                      onClick={() => void submitClose(item)}
                      className={cn(
                        "inline-flex min-h-11 items-center gap-2 rounded-lg px-4 text-xs font-semibold text-white disabled:opacity-60",
                        closeTarget.mode === "resolve"
                          ? "bg-emerald-600 hover:bg-emerald-700"
                          : "bg-danger hover:bg-red-700",
                      )}
                    >
                      {itemBusy && <Loader2 className="size-4 animate-spin" />}
                      Definitief bevestigen
                    </button>
                  </div>
                </div>
              )}

              {item.status === "resolved" || item.status === "dismissed" ? (
                <div className="mt-4 rounded-lg bg-slate-50 px-3 py-2 text-xs text-slate-600">
                  {item.status === "resolved" ? "Oplossing" : "Afwijsreden"}:{" "}
                  <span className="font-medium text-ink">{item.resolutionReason}</span>
                  <span className="ml-2 text-slate-500">
                    {formatDate(item.resolvedAt)}
                  </span>
                </div>
              ) : null}
            </article>
          );
        })}
      </section>

      <footer className="mt-5 flex flex-col items-center justify-between gap-3 rounded-xl border border-line bg-white px-4 py-3 text-xs text-slate-500 sm:flex-row">
        <span>{firstResult}–{lastResult} van {workspace.total} resultaten</span>
        <div className="flex gap-2">
          <button
            type="button"
            disabled={busy !== null || workspace.offset === 0}
            onClick={() => void query(Math.max(0, workspace.offset - workspace.limit))}
            className="min-h-11 rounded-lg border border-line px-4 font-semibold text-brand-700 disabled:opacity-40"
          >
            Vorige
          </button>
          <button
            type="button"
            disabled={busy !== null || workspace.offset + workspace.limit >= workspace.total}
            onClick={() => void query(workspace.offset + workspace.limit)}
            className="min-h-11 rounded-lg border border-line px-4 font-semibold text-brand-700 disabled:opacity-40"
          >
            Volgende
          </button>
        </div>
      </footer>
    </div>
  );
}
