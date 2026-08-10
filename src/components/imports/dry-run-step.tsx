"use client";

import {
  AlertTriangle,
  CheckCircle2,
  Eye,
  Loader2,
  Play,
  ShieldCheck,
  X,
} from "lucide-react";
import { useCallback, useEffect, useState } from "react";
import {
  dynamicImportCommitStartResponseSchema,
  dynamicImportBlockedRowSchema,
  dynamicImportDryRunSchema,
  dynamicImportDryRunStartResponseSchema,
  type DynamicImportRunStatus,
  type DynamicImportBlockedRow,
  type DynamicImportDryRun,
  type DynamicImportMappingResponse,
} from "@/lib/import-contract";

const outcomeLabels = {
  create: "Nieuw",
  update: "Bijwerken",
  skip: "Ongewijzigd",
  protected: "Beschermd",
  conflict: "Conflict",
  error: "Fout",
} as const;

const reasonLabels: Record<string, string> = {
  confirmed_size_protected: "Bevestigde maat blijft ongewijzigd",
  date_of_birth_mismatch: "Geboortedatum wijkt af",
  duplicate_source_identity: "Dubbele identiteit in dit bestand",
  duplicate_target_member: "Meerdere rijen wijzen naar hetzelfde lid",
  email_identity_mismatch: "E-mailadres past niet bij naam en geboortedatum",
  external_identity_requires_review: "Nieuw relatienummer lijkt bij een bestaand lid te horen",
  identity_ambiguous: "Meerdere bestaande leden passen exact",
  identity_cross_match: "Relatienummer en naam/geboortedatum wijzen naar verschillende leden",
  identity_insufficient: "Onvoldoende veilige identiteitsvelden",
  invalid_row_shape: "Afwijkend aantal CSV-kolommen",
  missing_first_name: "Voornaam ontbreekt",
  missing_last_name: "Achternaam ontbreekt",
  missing_team: "Team ontbreekt",
  unknown_size: "Onbekende maat; beheeractie wordt aangemaakt",
};

const fieldLabels: Record<string, string> = {
  external_member_id: "Relatienummer",
  first_name: "Voornaam",
  insertion: "Tussenvoegsel",
  last_name: "Achternaam",
  email: "E-mailadres",
  team: "Team",
  date_of_birth: "Geboortedatum",
  gender: "Geslacht",
  active_for_season: "Actief in seizoen",
};

const PAGE_SIZE = 100;
const POLL_RETRY_DELAYS_MS = [1_500, 3_000, 6_000, 10_000] as const;
type OutcomeFilter = "" | keyof typeof outcomeLabels;

type Props = {
  batchId?: string;
  mapping?: DynamicImportMappingResponse;
  initialRunId?: string;
  onStatus?: (status: DynamicImportRunStatus) => void;
};

function apiMessage(body: unknown, fallback: string) {
  return body
    && typeof body === "object"
    && "error" in body
    && typeof body.error === "string"
    ? body.error
    : fallback;
}

export function DryRunStep({
  batchId,
  mapping,
  initialRunId,
  onStatus,
}: Props) {
  const [dryRunRequestId] = useState(() => crypto.randomUUID());
  const [commitRequestId] = useState(() => crypto.randomUUID());
  const [runId, setRunId] = useState<string | null>(initialRunId ?? null);
  const [result, setResult] = useState<DynamicImportDryRun | null>(null);
  const [confirmed, setConfirmed] = useState(false);
  const [busy, setBusy] = useState<"starting" | "committing" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [outcomeFilter, setOutcomeFilter] = useState<OutcomeFilter>("");
  const [offset, setOffset] = useState(0);
  const [pollCycle, setPollCycle] = useState(0);
  const [pollingStopped, setPollingStopped] = useState(false);
  const [blockedDetail, setBlockedDetail] =
    useState<DynamicImportBlockedRow | null>(null);
  const [detailBusyRow, setDetailBusyRow] = useState<number | null>(null);

  const refresh = useCallback(async (
    targetRunId: string,
    targetOffset = offset,
    targetOutcome: OutcomeFilter = outcomeFilter,
  ) => {
    const params = new URLSearchParams({
      runId: targetRunId,
      offset: String(targetOffset),
      limit: String(PAGE_SIZE),
    });
    if (targetOutcome) params.set("outcome", targetOutcome);
    const response = await fetch(
      `/api/imports/dry-runs?${params.toString()}`,
      { cache: "no-store" },
    );
    const body: unknown = await response.json();
    if (!response.ok) {
      throw new Error(apiMessage(body, "De dry-runstatus kon niet worden geladen."));
    }
    const parsed = dynamicImportDryRunSchema.safeParse(body);
    if (!parsed.success) throw new Error("De server gaf een ongeldig dry-runresultaat terug.");
    setError(null);
    setResult(parsed.data);
    onStatus?.(parsed.data.status);
    return parsed.data;
  }, [offset, onStatus, outcomeFilter]);

  useEffect(() => {
    if (!runId) return;
    let active = true;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let retryCount = 0;
    setPollingStopped(false);
    const poll = async (): Promise<void> => {
      try {
        const next = await refresh(runId);
        retryCount = 0;
        if (
          active
          && ["queued_preview", "staging", "commit_queued", "committing"].includes(next.status)
        ) {
          timer = setTimeout(() => void poll(), 1_500);
        }
      } catch (cause) {
        if (!active) return;
        setError(cause instanceof Error ? cause.message : "De dry-runstatus kon niet worden geladen.");
        if (retryCount < POLL_RETRY_DELAYS_MS.length) {
          const delay = POLL_RETRY_DELAYS_MS[retryCount];
          retryCount += 1;
          timer = setTimeout(() => void poll(), delay);
        } else {
          setPollingStopped(true);
        }
      }
    };
    void poll();
    return () => {
      active = false;
      if (timer) clearTimeout(timer);
    };
  }, [pollCycle, refresh, runId]);

  async function startDryRun() {
    if (!batchId || !mapping) return;
    setBusy("starting");
    setError(null);
    try {
      const response = await fetch("/api/imports/dry-runs", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Duindorp-CSRF": "same-origin",
        },
        body: JSON.stringify({
          batchId,
          mappingRevision: mapping.revision,
          clientRequestId: dryRunRequestId,
        }),
      });
      const body: unknown = await response.json();
      if (!response.ok) {
        throw new Error(apiMessage(body, "De dry-run kon niet worden gestart."));
      }
      const parsed = dynamicImportDryRunStartResponseSchema.safeParse(body);
      if (!parsed.success) throw new Error("De server gaf een ongeldig dry-runantwoord terug.");
      setOffset(0);
      setOutcomeFilter("");
      setRunId(parsed.data.runId);
      await refresh(parsed.data.runId, 0, "");
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "De dry-run kon niet worden gestart.");
    } finally {
      setBusy(null);
    }
  }

  async function commitImport() {
    if (!result?.planHash || !confirmed) return;
    setBusy("committing");
    setError(null);
    try {
      const response = await fetch("/api/imports/commits", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Duindorp-CSRF": "same-origin",
        },
        body: JSON.stringify({
          runId: result.runId,
          planHash: result.planHash,
          clientRequestId: commitRequestId,
          confirmed: true,
        }),
      });
      const body: unknown = await response.json();
      if (!response.ok) {
        throw new Error(apiMessage(body, "De import kon niet definitief worden gestart."));
      }
      const parsed = dynamicImportCommitStartResponseSchema.safeParse(body);
      if (!parsed.success) throw new Error("De server gaf een ongeldig commitantwoord terug.");
      setRunId(parsed.data.runId);
      setPollCycle((cycle) => cycle + 1);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "De import kon niet definitief worden gestart.");
    } finally {
      setBusy(null);
    }
  }

  async function loadBlockedDetail(sourceRow: number) {
    if (!runId) return;
    setDetailBusyRow(sourceRow);
    setError(null);
    try {
      const params = new URLSearchParams({
        runId,
        sourceRow: String(sourceRow),
      });
      const response = await fetch(
        `/api/imports/dry-runs/blocked-row?${params.toString()}`,
        { cache: "no-store" },
      );
      const body: unknown = await response.json();
      if (!response.ok) {
        throw new Error(apiMessage(
          body,
          "De tijdelijke conflictdetails konden niet worden geladen.",
        ));
      }
      const parsed = dynamicImportBlockedRowSchema.safeParse(body);
      if (!parsed.success) {
        throw new Error("De server gaf ongeldige conflictdetails terug.");
      }
      setBlockedDetail(parsed.data);
    } catch (cause) {
      setError(cause instanceof Error
        ? cause.message
        : "De tijdelijke conflictdetails konden niet worden geladen.");
    } finally {
      setDetailBusyRow(null);
    }
  }

  const processing = result
    && ["queued_preview", "staging", "commit_queued", "committing"].includes(result.status);
  const previewReady = result?.status === "previewed";
  const committed = result?.status === "committed";
  const failed = result?.status === "failed";
  const expired = result?.status === "expired";

  return (
    <section className="border-t border-line pt-6" aria-labelledby="dry-run-title">
      <p className="text-[11px] font-semibold uppercase tracking-[0.1em] text-brand-500">Stap 3</p>
      <h2 id="dry-run-title" className="mt-1 text-lg font-bold text-brand-900">Volledige dry-run</h2>
      <p className="mt-1 text-xs leading-5 text-slate-500">
        Identiteit, seizoen, maten en beschermde keuzes worden gecontroleerd zonder leden te wijzigen.
      </p>

      {!runId && batchId && mapping && (
        <button
          type="button"
          disabled={busy !== null}
          onClick={() => void startDryRun()}
          className="mt-4 inline-flex h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 disabled:bg-slate-200 disabled:text-slate-400"
        >
          {busy === "starting" ? <Loader2 className="size-4 animate-spin" /> : <Play className="size-4" />}
          {busy === "starting" ? "Dry-run queueën…" : "Dry-run starten"}
        </button>
      )}

      {error && (
        <div className="mt-4 rounded-lg bg-red-50 p-3 text-xs text-danger" role="alert">
          <div className="flex items-start gap-2">
            <AlertTriangle className="mt-0.5 size-4 shrink-0" />{error}
          </div>
          {pollingStopped && runId && (
            <button
              type="button"
              onClick={() => {
                setPollingStopped(false);
                setPollCycle((cycle) => cycle + 1);
              }}
              className="mt-3 h-9 rounded-md border border-red-200 bg-white px-3 text-[11px] font-semibold text-red-800"
            >
              Status opnieuw laden
            </button>
          )}
        </div>
      )}

      {result && (
        <div className="mt-5 space-y-5" aria-live="polite">
          {processing && (
            <div className="flex items-start gap-3 rounded-lg border border-brand-100 bg-brand-50 p-4">
              <Loader2 className="mt-0.5 size-5 shrink-0 animate-spin text-brand-700" />
              <div>
                <h3 className="text-sm font-bold text-brand-950">
                  {result.status === "commit_queued" || result.status === "committing"
                    ? "Import transactioneel verwerken"
                    : "Alle rijen controleren"}
                </h3>
                <p className="mt-1 text-xs leading-5 text-brand-900">
                  {result.status === "commit_queued" || result.status === "committing"
                    ? `${result.committedRowCount} van ${result.sourceRowCount} rijen definitief verwerkt.`
                    : `${result.processedRowCount} van ${result.sourceRowCount} rijen veilig geprojecteerd.`}
                </p>
              </div>
            </div>
          )}

          {committed && (
            <div className="flex items-start gap-3 rounded-lg border border-emerald-100 bg-emerald-50 p-4">
              <CheckCircle2 className="mt-0.5 size-5 shrink-0 text-success" />
              <div>
                <h3 className="text-sm font-bold text-emerald-950">Import voltooid</h3>
                <p className="mt-1 text-xs leading-5 text-emerald-900">
                  Leden, lid-seizoenen en geselecteerde maten zijn verwerkt. Er is geen toegang geactiveerd en geen e-mail verstuurd.
                </p>
              </div>
            </div>
          )}

          {(failed || expired) && (
            <div className="flex items-start gap-3 rounded-lg border border-red-200 bg-red-50 p-4">
              <AlertTriangle className="mt-0.5 size-5 shrink-0 text-danger" />
              <div>
                <h3 className="text-sm font-bold text-red-950">
                  {expired ? "Import verlopen" : "Import veilig gestopt"}
                </h3>
                <p className="mt-1 text-xs leading-5 text-red-900">
                  {expired
                    ? "De tijdelijke importgegevens zijn volgens de bewaartermijn verwijderd. Upload het bestand opnieuw en voer een nieuwe dry-run uit."
                    : "De bron of toestand is gewijzigd. Er is een beheeractie aangemaakt; controleer die voordat je opnieuw uploadt."}
                </p>
              </div>
            </div>
          )}

          {(previewReady || committed) && (
            <>
              <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
                {(Object.keys(outcomeLabels) as Array<keyof typeof outcomeLabels>).map((outcome) => (
                  <div key={outcome} className="rounded-lg border border-line bg-slate-50 p-3">
                    <p className="text-[10px] font-semibold uppercase tracking-[0.08em] text-slate-400">{outcomeLabels[outcome]}</p>
                    <p className="mt-1 text-xl font-bold text-brand-900">{result.outcomeCounts[outcome]}</p>
                  </div>
                ))}
              </div>

              {(result.rows.length > 0 || outcomeFilter) && (
                <div className="overflow-hidden rounded-lg border border-line">
                  <div className="flex flex-col gap-2 border-b border-line bg-slate-50 p-3 sm:flex-row sm:items-center sm:justify-between">
                    <label className="flex items-center gap-2 text-[11px] font-semibold text-slate-600">
                      Uitkomst
                      <select
                        value={outcomeFilter}
                        onChange={(event) => {
                          setOutcomeFilter(event.target.value as OutcomeFilter);
                          setOffset(0);
                        }}
                        className="h-9 rounded-md border border-line bg-white px-2 text-xs text-ink outline-none focus-visible:ring-2 focus-visible:ring-brand-500"
                      >
                        <option value="">Alle uitkomsten</option>
                        {(Object.keys(outcomeLabels) as Array<keyof typeof outcomeLabels>).map((outcome) => (
                          <option key={outcome} value={outcome}>{outcomeLabels[outcome]}</option>
                        ))}
                      </select>
                    </label>
                    <p className="text-[10px] text-slate-500">
                      {result.filteredTotal === 0
                        ? "Geen rijen"
                        : `${result.offset + 1}–${Math.min(result.offset + result.rows.length, result.filteredTotal)} van ${result.filteredTotal}`}
                    </p>
                  </div>
                  <table className="w-full text-left text-xs">
                    <thead className="bg-slate-50 text-[10px] uppercase tracking-[0.08em] text-slate-500">
                      <tr><th className="px-3 py-2">CSV-rij</th><th className="px-3 py-2">Uitkomst</th><th className="px-3 py-2">Toelichting</th></tr>
                    </thead>
                    <tbody className="divide-y divide-line">
                      {result.rows.length === 0 && (
                        <tr>
                          <td colSpan={3} className="px-3 py-6 text-center text-slate-500">
                            Geen rijen met deze uitkomst.
                          </td>
                        </tr>
                      )}
                      {result.rows.map((row) => (
                        <tr key={row.sourceRow}>
                          <td className="px-3 py-2 font-semibold text-ink">{row.sourceRow}</td>
                          <td className="px-3 py-2 text-brand-800">{outcomeLabels[row.outcome]}</td>
                          <td className="px-3 py-2 text-slate-500">
                            <span>
                              {row.reasonCodes.length > 0
                                ? row.reasonCodes.map((reason) => reasonLabels[reason] ?? reason).join(" · ")
                                : `${row.changeCount} wijziging(en)`}
                            </span>
                            {row.blocking && (
                              <button
                                type="button"
                                onClick={() => void loadBlockedDetail(row.sourceRow)}
                                disabled={detailBusyRow !== null}
                                className="mt-2 inline-flex h-8 items-center gap-1 rounded-md border border-line bg-white px-2 text-[10px] font-semibold text-brand-800 disabled:text-slate-300"
                              >
                                {detailBusyRow === row.sourceRow
                                  ? <Loader2 className="size-3 animate-spin" />
                                  : <Eye className="size-3" />}
                                Tijdelijke details
                              </button>
                            )}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                  <div className="flex items-center justify-between border-t border-line bg-slate-50 px-3 py-2">
                    <button
                      type="button"
                      disabled={result.offset === 0}
                      onClick={() => setOffset(Math.max(0, result.offset - result.limit))}
                      className="h-9 rounded-md border border-line bg-white px-3 text-[11px] font-semibold text-brand-800 disabled:text-slate-300"
                    >
                      Vorige
                    </button>
                    <button
                      type="button"
                      disabled={result.offset + result.rows.length >= result.filteredTotal}
                      onClick={() => setOffset(result.offset + result.limit)}
                      className="h-9 rounded-md border border-line bg-white px-3 text-[11px] font-semibold text-brand-800 disabled:text-slate-300"
                    >
                      Volgende
                    </button>
                  </div>
                </div>
              )}

              {blockedDetail && (
                <aside
                  className="rounded-lg border border-amber-200 bg-amber-50 p-4"
                  aria-labelledby="blocked-row-detail-title"
                >
                  <div className="flex items-start justify-between gap-3">
                    <div>
                      <h3
                        id="blocked-row-detail-title"
                        className="text-sm font-bold text-amber-950"
                      >
                        Conflictdetails CSV-rij {blockedDetail.sourceRow}
                      </h3>
                      <p className="mt-1 text-[11px] leading-5 text-amber-900">
                        Alleen daadwerkelijk geselecteerde kolommen worden tijdelijk getoond. Corrigeer de bron en upload opnieuw; er wordt nooit automatisch op identiteit gegokt.
                      </p>
                    </div>
                    <button
                      type="button"
                      onClick={() => setBlockedDetail(null)}
                      aria-label="Conflictdetails sluiten"
                      className="grid size-9 shrink-0 place-items-center rounded-md border border-amber-200 bg-white text-amber-900"
                    >
                      <X className="size-4" />
                    </button>
                  </div>
                  <dl className="mt-4 grid gap-2 sm:grid-cols-2">
                    {Object.entries(blockedDetail.fields).map(([field, value]) => (
                      <div key={field} className="rounded-md bg-white p-3">
                        <dt className="text-[10px] font-semibold uppercase tracking-[0.08em] text-slate-500">
                          {fieldLabels[field] ?? field}
                        </dt>
                        <dd className="mt-1 break-words text-xs font-semibold text-ink">
                          {typeof value === "boolean"
                            ? (value ? "Ja" : "Nee")
                            : value}
                        </dd>
                      </div>
                    ))}
                    {blockedDetail.sizes.map((size) => (
                      <div key={size.articleId} className="rounded-md bg-white p-3">
                        <dt className="text-[10px] font-semibold uppercase tracking-[0.08em] text-slate-500">
                          Maat {size.articleName}
                        </dt>
                        <dd className="mt-1 break-words text-xs font-semibold text-ink">
                          {size.sourceValue}
                        </dd>
                      </div>
                    ))}
                  </dl>
                  <p className="mt-3 text-[10px] text-amber-800">
                    Deze details worden uiterlijk op {new Intl.DateTimeFormat(
                      "nl-NL",
                      { dateStyle: "medium", timeStyle: "short" },
                    ).format(new Date(blockedDetail.expiresAt))} verwijderd.
                  </p>
                </aside>
              )}
            </>
          )}

          {previewReady && (
            <div className={`rounded-lg border p-4 ${result.hasBlockers ? "border-amber-200 bg-amber-50" : "border-brand-100 bg-brand-50"}`}>
              {result.hasBlockers && (
                <div className="mb-4 flex items-start gap-2 text-xs text-amber-950">
                  <AlertTriangle className="mt-0.5 size-4 shrink-0" />
                  <span>Blokkerende rijen worden niet gewijzigd en krijgen ieder één beheeractie. Alleen de aantoonbaar veilige rijen hieronder worden verwerkt; er wordt nooit op identiteit gegokt.</span>
                </div>
              )}
              <label className="flex cursor-pointer items-start gap-3 text-xs leading-5 text-brand-950">
                <input
                  type="checkbox"
                  checked={confirmed}
                  onChange={(event) => setConfirmed(event.target.checked)}
                  className="mt-1 size-4 rounded border-brand-300 text-brand-700"
                />
                <span>
                  Ik bevestig dit exacte dry-runplan. Blokkerende rijen worden overgeslagen, onbekende maten worden beheerconflicten en bevestigde keuzes blijven beschermd. Er worden geen accounts, uitnodigingen of mails aangemaakt.
                </span>
              </label>
              <button
                type="button"
                disabled={!confirmed || busy !== null}
                onClick={() => void commitImport()}
                className="mt-4 inline-flex h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 disabled:bg-slate-200 disabled:text-slate-400"
              >
                {busy === "committing" ? <Loader2 className="size-4 animate-spin" /> : <ShieldCheck className="size-4" />}
                {busy === "committing" ? "Commit queueën…" : "Veilige rijen definitief importeren"}
              </button>
            </div>
          )}
        </div>
      )}
    </section>
  );
}
