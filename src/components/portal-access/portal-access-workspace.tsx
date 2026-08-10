"use client";

import {
  AlertTriangle,
  ArrowLeft,
  ArrowRight,
  Check,
  KeyRound,
  Loader2,
  MailCheck,
  Search,
  ShieldCheck,
  UserMinus,
  UserPlus,
  UsersRound,
} from "lucide-react";
import { FormEvent, useEffect, useMemo, useState } from "react";
import {
  MEMBER_BULK_CONTEXT_STORAGE_KEY,
  parseFreshMemberBulkContext,
} from "@/lib/member-bulk-contract";
import {
  portalAccessCommitResponseSchema,
  portalAccessPreviewResponseSchema,
  portalAccessWorkspaceSchema,
  type PortalAccessCommitResponse,
  type PortalAccessPreviewResponse,
  type PortalAccessWorkspaceData,
} from "@/lib/portal-access-contract";
import { cn } from "@/lib/utils";

type AccessMode = "activate" | "revoke";
type MemberRow = PortalAccessWorkspaceData["members"][number];

const blockerLabels: Record<string, string> = {
  member_season_not_found: "Lid-seizoen bestaat niet meer",
  season_mismatch: "Lid hoort bij een ander seizoen",
  member_not_active: "Lid is niet actief",
  member_season_unresolved: "Lid-seizoen moet eerst worden gecontroleerd",
  email_invalid: "E-mailadres ontbreekt of is ongeldig",
  conflicting_portal_grant: "Er bestaat een conflicterende portaalgrant",
  suspicious_family_link: "Bestaande gezinskoppeling vereist controle",
  grant_not_found: "Grant bestaat niet meer",
};

const grantLabels = {
  pending_account: "Account wacht",
  review_required: "Controle nodig",
  active: "Actief",
  revoked: "Ingetrokken",
};

function fullName(member: Pick<MemberRow, "firstName" | "insertion" | "lastName">) {
  return [member.firstName, member.insertion, member.lastName].filter(Boolean).join(" ");
}

function requestHeaders() {
  return {
    "Content-Type": "application/json",
    "X-Duindorp-CSRF": "same-origin",
  };
}

export function PortalAccessWorkspace({ initial }: { initial: PortalAccessWorkspaceData }) {
  const [workspace, setWorkspace] = useState(initial);
  const [mode, setMode] = useState<AccessMode>("activate");
  const [search, setSearch] = useState("");
  const [selected, setSelected] = useState<Map<string, MemberRow | null>>(
    new Map(),
  );
  const [preview, setPreview] = useState<PortalAccessPreviewResponse | null>(null);
  const [batchKey, setBatchKey] = useState<string | null>(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState<"query" | "preview" | "commit" | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<PortalAccessCommitResponse | null>(null);

  const selectedRows = useMemo(
    () => [...selected.values()].filter(
      (member): member is MemberRow => member !== null,
    ),
    [selected],
  );
  const visibleSelectable = workspace.members.filter((member) => (
    mode === "activate"
      ? true
      : Boolean(member.grant && member.grant.status !== "revoked")
  ));
  const allVisibleSelected = visibleSelectable.length > 0
    && visibleSelectable.every((member) => selected.has(member.memberSeasonId));
  const firstResult = workspace.total === 0 ? 0 : workspace.offset + 1;
  const lastResult = Math.min(workspace.offset + workspace.limit, workspace.total);

  useEffect(() => {
    const raw = window.sessionStorage.getItem(
      MEMBER_BULK_CONTEXT_STORAGE_KEY,
    );
    const context = parseFreshMemberBulkContext(raw, "portal_access");
    if (!context) {
      if (raw) {
        window.sessionStorage.removeItem(MEMBER_BULK_CONTEXT_STORAGE_KEY);
      }
      return;
    }
    window.sessionStorage.removeItem(MEMBER_BULK_CONTEXT_STORAGE_KEY);
    if (context.seasonId !== workspace.selectedSeason.id) {
      setError(
        "De ledenselectie hoort bij een ander seizoen. Selecteer de leden opnieuw.",
      );
      return;
    }
    setMode("activate");
    setSelected(new Map(
      context.entries.map((entry) => [entry.memberSeasonId, null]),
    ));
  }, [workspace.selectedSeason.id]);

  function clearPreparedState() {
    setPreview(null);
    setBatchKey(null);
    setSuccess(null);
    setError(null);
  }

  function changeMode(next: AccessMode) {
    setMode(next);
    setSelected(new Map());
    setReason("");
    clearPreparedState();
  }

  function toggleMember(member: MemberRow) {
    const selectable = mode === "activate"
      || Boolean(member.grant && member.grant.status !== "revoked");
    if (!selectable) return;
    setSelected((current) => {
      const next = new Map(current);
      if (next.has(member.memberSeasonId)) next.delete(member.memberSeasonId);
      else if (next.size < 500) next.set(member.memberSeasonId, member);
      return next;
    });
    clearPreparedState();
  }

  function toggleVisible() {
    setSelected((current) => {
      const next = new Map(current);
      if (allVisibleSelected) {
        for (const member of visibleSelectable) next.delete(member.memberSeasonId);
      } else {
        for (const member of visibleSelectable) {
          if (next.size < 500) next.set(member.memberSeasonId, member);
        }
      }
      return next;
    });
    clearPreparedState();
  }

  async function query(offset: number, nextSeasonId = workspace.selectedSeason.id) {
    setBusy("query");
    setError(null);
    setSuccess(null);
    try {
      const response = await fetch("/api/portal-access/query", {
        method: "POST",
        headers: requestHeaders(),
        body: JSON.stringify({
          seasonId: nextSeasonId,
          search: search.trim() || null,
          offset,
          limit: 50,
        }),
        cache: "no-store",
      });
      const payload: unknown = await response.json();
      if (!response.ok) throw new Error(
        typeof payload === "object" && payload && "error" in payload
          ? String(payload.error)
          : "De leden konden niet worden geladen.",
      );
      const parsed = portalAccessWorkspaceSchema.safeParse(payload);
      if (!parsed.success) throw new Error("De ledenrespons is ongeldig.");
      setWorkspace(parsed.data);
    } catch (queryError) {
      setError(queryError instanceof Error ? queryError.message : "De leden konden niet worden geladen.");
    } finally {
      setBusy(null);
    }
  }

  async function submitSearch(event: FormEvent) {
    event.preventDefault();
    await query(0);
  }

  async function prepare() {
    if (selected.size === 0) {
      setError("Selecteer minimaal één lid.");
      return;
    }
    const grantIds = selectedRows.flatMap((member) => (
      member.grant && member.grant.status !== "revoked" ? [member.grant.id] : []
    ));
    if (mode === "revoke" && grantIds.length !== selectedRows.length) {
      setError("Een geselecteerd lid heeft geen intrekbare grant. Vernieuw de lijst.");
      return;
    }
    setBusy("preview");
    setError(null);
    setSuccess(null);
    try {
      const response = await fetch("/api/portal-access/preflight", {
        method: "POST",
        headers: requestHeaders(),
        body: JSON.stringify(mode === "activate" ? {
          operation: "activate",
          seasonId: workspace.selectedSeason.id,
          memberSeasonIds: [...selected.keys()],
        } : {
          operation: "revoke",
          seasonId: workspace.selectedSeason.id,
          grantIds,
        }),
      });
      const payload: unknown = await response.json();
      if (!response.ok) throw new Error(
        typeof payload === "object" && payload && "error" in payload
          ? String(payload.error)
          : "De controle kon niet worden uitgevoerd.",
      );
      const parsed = portalAccessPreviewResponseSchema.safeParse(payload);
      if (!parsed.success) throw new Error("De controlerespons is ongeldig.");
      setPreview(parsed.data);
      setBatchKey(crypto.randomUUID());
    } catch (previewError) {
      setError(previewError instanceof Error ? previewError.message : "De controle kon niet worden uitgevoerd.");
    } finally {
      setBusy(null);
    }
  }

  async function commit() {
    if (!preview || !batchKey || preview.blockedCount > 0) return;
    if (mode === "revoke" && reason.trim().length < 3) {
      setError("Vul voor intrekken een reden van minimaal drie tekens in.");
      return;
    }
    const grantIds = selectedRows.flatMap((member) => member.grant ? [member.grant.id] : []);
    setBusy("commit");
    setError(null);
    try {
      const response = await fetch(`/api/portal-access/${mode === "activate" ? "activate" : "revoke"}`, {
        method: "POST",
        headers: requestHeaders(),
        body: JSON.stringify(mode === "activate" ? {
          seasonId: workspace.selectedSeason.id,
          memberSeasonIds: [...selected.keys()],
          previewToken: preview.previewToken,
          batchKey,
        } : {
          seasonId: workspace.selectedSeason.id,
          grantIds,
          reason: reason.trim(),
          previewToken: preview.previewToken,
          batchKey,
        }),
      });
      const payload: unknown = await response.json();
      if (!response.ok) throw new Error(
        typeof payload === "object" && payload && "error" in payload
          ? String(payload.error)
          : "De toegangshandeling is niet uitgevoerd.",
      );
      const parsed = portalAccessCommitResponseSchema.safeParse(payload);
      if (!parsed.success) throw new Error("De bevestigingsrespons is ongeldig.");
      setSuccess(parsed.data);
      setSelected(new Map());
      setPreview(null);
      setBatchKey(null);
      setReason("");
      await query(workspace.offset);
      setSuccess(parsed.data);
    } catch (commitError) {
      setError(commitError instanceof Error ? commitError.message : "De toegangshandeling is niet uitgevoerd.");
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="mx-auto max-w-[1440px]">
      <header className="flex flex-col justify-between gap-4 lg:flex-row lg:items-end">
        <div>
          <p className="text-xs font-semibold uppercase tracking-[0.12em] text-brand-500">Beheer en privacy</p>
          <h1 className="mt-2 text-[30px] font-bold tracking-[-0.04em] text-brand-900 md:text-[34px]">Portaaltoegang</h1>
          <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-600">
            Activeer of trek toegang expliciet per lid en seizoen in. Een import maakt nooit automatisch een ouderaccount of uitnodiging.
          </p>
        </div>
        <div className="inline-flex h-10 items-center gap-2 self-start rounded-lg border border-emerald-200 bg-emerald-50 px-3 text-xs font-bold text-success">
          <ShieldCheck className="size-4" /> Beheerder · MFA
        </div>
      </header>

      <section className="mt-7 rounded-xl border border-line bg-white p-4 shadow-card">
        <div className="flex flex-col gap-4 xl:flex-row xl:items-end">
          <div className="inline-flex self-start rounded-lg border border-line bg-slate-50 p-1" role="group" aria-label="Toegangshandeling">
            <button type="button" onClick={() => changeMode("activate")} className={cn("inline-flex min-h-10 items-center gap-2 rounded-md px-3 text-xs font-semibold", mode === "activate" ? "bg-white text-brand-700 shadow-sm" : "text-slate-500")}><UserPlus className="size-4" /> Activeren</button>
            <button type="button" onClick={() => changeMode("revoke")} className={cn("inline-flex min-h-10 items-center gap-2 rounded-md px-3 text-xs font-semibold", mode === "revoke" ? "bg-white text-danger shadow-sm" : "text-slate-500")}><UserMinus className="size-4" /> Intrekken</button>
          </div>
          <label className="min-w-52 text-xs font-semibold text-slate-600">
            Seizoen
            <select
              value={workspace.selectedSeason.id}
              onChange={(event) => {
                const nextSeasonId = event.target.value;
                setSelected(new Map());
                clearPreparedState();
                void query(0, nextSeasonId);
              }}
              className="mt-1.5 h-11 w-full rounded-lg border border-line bg-white px-3 text-sm text-ink focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-100"
            >
              {workspace.seasons.map((season) => <option key={season.id} value={season.id}>{season.name}{season.active ? " · actief" : ""}</option>)}
            </select>
          </label>
          <form onSubmit={submitSearch} className="flex flex-1 flex-col gap-2 sm:flex-row">
            <label className="relative flex-1 text-xs font-semibold text-slate-600">
              Zoeken
              <Search className="pointer-events-none absolute bottom-3.5 left-3 size-4 text-slate-400" />
              <input value={search} onChange={(event) => setSearch(event.target.value)} maxLength={120} placeholder="Naam, relatienummer, team of e-mail" className="mt-1.5 h-11 w-full rounded-lg border border-line pl-9 pr-3 text-sm text-ink focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-100" />
            </label>
            <button disabled={busy !== null} className="mt-auto inline-flex h-11 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 disabled:opacity-60">{busy === "query" && <Loader2 className="size-4 animate-spin" />} Zoeken</button>
          </form>
        </div>
        <p className="mt-3 text-[11px] text-slate-600">Zoekgegevens worden via een begrensd POST-verzoek verwerkt en komen niet in de browser-URL.</p>
      </section>

      {(error || success) && <div role={error ? "alert" : "status"} className={cn("mt-5 rounded-xl border px-4 py-3 text-sm", error ? "border-red-200 bg-red-50 text-danger" : "border-emerald-200 bg-emerald-50 text-success")}>{error ?? `${success?.changedCount ?? 0} toegang(en) bijgewerkt${success?.inviteJobCount ? ` · ${success.inviteJobCount} uitnodiging(en) klaargezet` : ""}.`}</div>}

      <div className="mt-6 grid items-start gap-6 xl:grid-cols-[minmax(0,1fr)_430px]">
        <section className="overflow-hidden rounded-xl border border-line bg-white shadow-card">
          <div className="flex flex-col gap-3 border-b border-line px-5 py-4 sm:flex-row sm:items-center sm:justify-between">
            <div><h2 className="text-sm font-bold text-brand-900">Leden in {workspace.selectedSeason.name}</h2><p className="mt-1 text-[11px] text-slate-500">{workspace.total.toLocaleString("nl-NL")} resultaat/resultaten · maximaal 500 per actie</p></div>
            <button type="button" onClick={toggleVisible} disabled={visibleSelectable.length === 0} className="inline-flex min-h-10 items-center gap-2 rounded-lg border border-line px-3 text-xs font-semibold text-brand-700 hover:border-brand-500 disabled:text-slate-300">{allVisibleSelected ? <Check className="size-4" /> : <UsersRound className="size-4" />}{allVisibleSelected ? "Zichtbare deselecteren" : "Selecteer zichtbare 50"}</button>
          </div>
          {workspace.members.length === 0 ? <div className="px-6 py-20 text-center"><UsersRound className="mx-auto size-8 text-slate-300" /><p className="mt-3 text-sm font-semibold text-slate-600">Geen leden gevonden</p></div> : <div className="overflow-x-auto">
            <table className="w-full min-w-[820px] text-left">
              <thead><tr className="border-b border-line bg-slate-50/70 text-[10px] font-bold uppercase tracking-[0.08em] text-slate-600"><th className="w-12 px-4 py-3"><span className="sr-only">Selectie</span></th><th className="px-3 py-3">Lid</th><th className="px-3 py-3">Team</th><th className="px-3 py-3">E-mail</th><th className="px-3 py-3">Toegang</th></tr></thead>
              <tbody className="divide-y divide-line">{workspace.members.map((member) => {
                const selectable = mode === "activate" || Boolean(member.grant && member.grant.status !== "revoked");
                const checked = selected.has(member.memberSeasonId);
                return <tr key={member.memberSeasonId} className={cn("hover:bg-brand-50/30", checked && "bg-brand-50/60", !selectable && "bg-slate-50")}>
                  <td className="px-4 py-3"><input type="checkbox" aria-label={`Selecteer ${fullName(member)}`} checked={checked} disabled={!selectable || (selected.size >= 500 && !checked)} onChange={() => toggleMember(member)} className="size-4 rounded border-slate-300 text-brand-700 focus:ring-brand-500" /></td>
                  <td className="px-3 py-3"><p className="text-xs font-semibold text-ink">{fullName(member)}</p><p className="mt-1 text-[10px] text-slate-600">{member.relationNumber ?? "Geen relatienummer"}</p></td>
                  <td className="px-3 py-3 text-xs text-slate-600">{member.team ?? "Niet ingevuld"}</td>
                  <td className="px-3 py-3"><p className={cn("text-xs font-medium", member.emailState === "valid" ? "text-slate-600" : "text-danger")}>{member.emailMasked ?? (member.emailState === "missing" ? "Ontbreekt" : "Ongeldig")}</p>{member.sharedEmailMemberCount > 1 && <p className="mt-1 text-[10px] text-brand-600">Gedeeld door {member.sharedEmailMemberCount} leden</p>}</td>
                  <td className="px-3 py-3">{member.grant ? <span className={cn("rounded-full px-2.5 py-1 text-[10px] font-semibold", member.grant.status === "active" ? "bg-emerald-50 text-success" : member.grant.status === "revoked" ? "bg-slate-100 text-slate-600" : "bg-amber-50 text-warning")}>{grantLabels[member.grant.status]}</span> : <span className="text-[11px] text-slate-600">Niet geactiveerd</span>}</td>
                </tr>;
              })}</tbody>
            </table>
          </div>}
          <div className="flex items-center justify-between gap-3 border-t border-line px-5 py-4">
            <p className="text-[11px] text-slate-600">{firstResult}–{lastResult} van {workspace.total.toLocaleString("nl-NL")}</p>
            <div className="flex gap-2">
              <button type="button" disabled={workspace.offset === 0 || busy !== null} onClick={() => void query(Math.max(0, workspace.offset - workspace.limit))} className="inline-flex min-h-10 items-center gap-2 rounded-lg border border-line px-3 text-xs font-semibold text-slate-600 disabled:text-slate-300"><ArrowLeft className="size-4" /> Vorige</button>
              <button type="button" disabled={workspace.offset + workspace.limit >= workspace.total || busy !== null} onClick={() => void query(workspace.offset + workspace.limit)} className="inline-flex min-h-10 items-center gap-2 rounded-lg border border-line px-3 text-xs font-semibold text-slate-600 disabled:text-slate-300">Volgende <ArrowRight className="size-4" /></button>
            </div>
          </div>
        </section>

        <aside className="space-y-5">
          <section className="rounded-xl border border-line bg-white p-5 shadow-card">
            <div className="flex items-center gap-2"><KeyRound className="size-4 text-brand-500" /><h2 className="text-sm font-bold text-brand-900">{mode === "activate" ? "Portaaltoegang activeren" : "Portaaltoegang intrekken"}</h2></div>
            <p className="mt-2 text-xs leading-5 text-slate-500">{selected.size} lid/leden geselecteerd. Alleen de expliciete selectie wordt verwerkt.</p>
            {mode === "revoke" && <label className="mt-4 block text-xs font-semibold text-slate-600">Reden voor intrekken<textarea value={reason} onChange={(event) => setReason(event.target.value)} maxLength={500} rows={3} className="mt-1.5 w-full rounded-lg border border-line p-3 text-sm font-normal text-ink focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-100" placeholder="Verplicht, minimaal drie tekens" /></label>}
            <button type="button" onClick={() => void prepare()} disabled={selected.size === 0 || busy !== null} className="mt-4 inline-flex min-h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 disabled:opacity-60">{busy === "preview" && <Loader2 className="size-4 animate-spin" />} Controleer selectie</button>
          </section>

          {preview && <section className="rounded-xl border border-brand-100 bg-white p-5 shadow-card">
            <div className="flex items-center justify-between gap-3"><h2 className="text-sm font-bold text-brand-900">Preflight</h2><span className="rounded-full bg-brand-50 px-2.5 py-1 text-[10px] font-semibold text-brand-700">10 minuten geldig</span></div>
            <div className="mt-4 grid grid-cols-3 gap-2 text-center"><div className="rounded-lg bg-emerald-50 p-2"><p className="text-lg font-bold text-success">{preview.eligibleCount}</p><p className="text-[9px] font-semibold text-success">Geschikt</p></div><div className="rounded-lg bg-slate-50 p-2"><p className="text-lg font-bold text-slate-600">{preview.unchangedCount}</p><p className="text-[9px] font-semibold text-slate-500">Ongewijzigd</p></div><div className="rounded-lg bg-red-50 p-2"><p className="text-lg font-bold text-danger">{preview.blockedCount}</p><p className="text-[9px] font-semibold text-danger">Geblokkeerd</p></div></div>
            <div className="mt-4 max-h-[380px] space-y-3 overflow-y-auto pr-1">{preview.groups.map((group) => <div key={group.key} className={cn("rounded-lg border p-3", group.status === "blocked" ? "border-red-200 bg-red-50/60" : "border-line bg-slate-50")}>
              <div className="flex items-start justify-between gap-3"><div><p className="break-all text-xs font-semibold text-ink">{group.email ?? "Geen geldig e-mailadres"}</p><p className="mt-1 text-[10px] text-slate-500">{group.existingAccount ? "Bestaand ouderaccount" : "Nieuw ouderaccount"} · {group.members.length} geselecteerd</p></div>{group.invitationRequired && <MailCheck className="size-4 shrink-0 text-brand-500" />}</div>
              {group.nonSelectedCount > 0 && <p className="mt-2 rounded-md bg-amber-50 px-2 py-1.5 text-[10px] text-warning">{group.nonSelectedCount} ander(e) lid/leden met dit adres {mode === "activate" ? "worden niet toegevoegd" : "behouden toegang"}.</p>}
              <ul className="mt-2 space-y-1">{group.members.map((member) => <li key={member.memberSeasonId} className="text-[11px] text-slate-600">{[member.firstName, member.insertion, member.lastName].filter(Boolean).join(" ") || "Onbekend lid"} · {member.team ?? "Geen team"}</li>)}</ul>
              {group.blockers.length > 0 && <ul className="mt-2 space-y-1 text-[10px] font-semibold text-danger">{group.blockers.map((blocker) => <li key={blocker} className="flex gap-1.5"><AlertTriangle className="mt-0.5 size-3 shrink-0" />{blockerLabels[blocker] ?? blocker}</li>)}</ul>}
            </div>)}</div>
            {preview.mailPreview && preview.eligibleCount > 0 && <div className="mt-4 rounded-lg border border-brand-100 bg-brand-50 p-3">
              <p className="text-[9px] font-bold uppercase tracking-[0.1em] text-brand-500">Mailvoorbeeld · templateversie {preview.mailPreview.templateVersion}</p>
              <p className="mt-2 text-xs font-bold text-brand-900">{preview.mailPreview.subject}</p>
              <p className="mt-2 whitespace-pre-wrap text-[10px] leading-5 text-slate-600">{preview.mailPreview.text}</p>
            </div>}
            {preview.blockedCount > 0 && <p className="mt-4 text-xs leading-5 text-danger">Verwijder geblokkeerde leden uit de selectie en voer de controle opnieuw uit. Er wordt nooit gedeeltelijk gecommit.</p>}
            <button type="button" onClick={() => void commit()} disabled={preview.blockedCount > 0 || busy !== null || (mode === "revoke" && reason.trim().length < 3)} className={cn("mt-4 inline-flex min-h-11 w-full items-center justify-center gap-2 rounded-lg px-4 text-xs font-semibold text-white disabled:opacity-50", mode === "activate" ? "bg-brand-700 hover:bg-brand-900" : "bg-red-700 hover:bg-red-800")}>{busy === "commit" ? <Loader2 className="size-4 animate-spin" /> : mode === "activate" ? <UserPlus className="size-4" /> : <UserMinus className="size-4" />}{mode === "activate" ? "Definitief activeren" : "Definitief intrekken"}</button>
          </section>}
        </aside>
      </div>
    </div>
  );
}
