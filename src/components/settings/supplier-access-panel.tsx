"use client";

import {
  AlertTriangle,
  Check,
  Clipboard,
  KeyRound,
  Loader2,
  Power,
  RefreshCw,
  Save,
  Truck,
  X,
} from "lucide-react";
import { type FormEvent, useEffect, useState } from "react";
import type { z } from "zod";
import type {
  supplierAdminWorkspaceSchema,
  supplierPrincipalSchema,
} from "@/lib/supplier-contract";

type Workspace = z.infer<typeof supplierAdminWorkspaceSchema>;
type Principal = z.infer<typeof supplierPrincipalSchema>;
type Notice = { tone: "success" | "error"; text: string } | null;

const inputClass = "mt-2 h-10 w-full rounded-lg border border-line bg-white px-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100";

export function SupplierAccessPanel() {
  const [workspace, setWorkspace] = useState<Workspace | null>(null);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [notice, setNotice] = useState<Notice>(null);
  const [displayName, setDisplayName] = useState("Free-Kick planning");
  const [newSeasonIds, setNewSeasonIds] = useState<string[]>([]);
  const [oneTimeToken, setOneTimeToken] = useState<string | null>(null);

  async function load() {
    setLoading(true);
    try {
      const response = await fetch("/api/settings/suppliers", {
        credentials: "same-origin",
        cache: "no-store",
      });
      const payload = await response.json() as Workspace & { error?: string };
      if (!response.ok) throw new Error(payload.error ?? "Laden mislukt.");
      setWorkspace(payload);
      setNewSeasonIds((current) => current.length > 0
        ? current.filter((id) => payload.seasons.some((season) => season.id === id))
        : payload.seasons[0]
          ? [payload.seasons[0].id]
          : []);
    } catch (error) {
      setNotice({
        tone: "error",
        text: error instanceof Error
          ? error.message
          : "Leverancierstoegang kon niet worden geladen.",
      });
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void load();
  }, []);

  async function action(body: Record<string, unknown>) {
    const response = await fetch("/api/settings/suppliers", {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        "X-Duindorp-CSRF": "same-origin",
      },
      body: JSON.stringify({ ...body, requestId: crypto.randomUUID() }),
    });
    const payload = await response.json() as {
      accessToken?: string;
      error?: string;
    };
    if (!response.ok) throw new Error(payload.error ?? "Actie mislukt.");
    if (payload.accessToken) setOneTimeToken(payload.accessToken);
    await load();
  }

  async function create(event: FormEvent) {
    event.preventDefault();
    if (newSeasonIds.length === 0) {
      setNotice({ tone: "error", text: "Selecteer minimaal één open seizoen." });
      return;
    }
    setBusy("create");
    setNotice(null);
    setOneTimeToken(null);
    try {
      await action({
        action: "create",
        displayName,
        seasonIds: newSeasonIds,
      });
      setNotice({
        tone: "success",
        text: "Toegang aangemaakt. Kopieer de sleutel nu; hij wordt niet opnieuw getoond.",
      });
    } catch (error) {
      setNotice({
        tone: "error",
        text: error instanceof Error ? error.message : "Aanmaken mislukt.",
      });
    } finally {
      setBusy(null);
    }
  }

  async function manage(
    principal: Principal,
    form: HTMLFormElement,
    actionName: "rotate" | "disable" | "set_seasons",
  ) {
    const data = new FormData(form);
    const reason = String(data.get("reason") ?? "").trim();
    const seasonIds = data.getAll("seasonIds").map(String);
    setBusy(`${principal.id}:${actionName}`);
    setNotice(null);
    if (actionName === "rotate") setOneTimeToken(null);
    try {
      await action({
        action: actionName,
        principalId: principal.id,
        reason,
        ...(actionName === "set_seasons" ? { seasonIds } : {}),
      });
      setNotice({
        tone: "success",
        text: actionName === "rotate"
          ? "Sleutel geroteerd; alle oude sessies zijn ingetrokken. Kopieer de nieuwe sleutel nu."
          : actionName === "disable"
            ? "Toegang en alle actieve sessies zijn ingetrokken."
            : "Seizoentoegang opgeslagen; bestaande sessies zijn uit voorzorg ingetrokken.",
      });
    } catch (error) {
      setNotice({
        tone: "error",
        text: error instanceof Error ? error.message : "Actie mislukt.",
      });
    } finally {
      setBusy(null);
    }
  }

  async function copyToken() {
    if (!oneTimeToken) return;
    await navigator.clipboard.writeText(oneTimeToken);
    setNotice({ tone: "success", text: "De eenmalige sleutel is naar het klembord gekopieerd." });
  }

  return <section className="overflow-hidden rounded-xl border border-line bg-white shadow-card">
    <div className="border-b border-line px-6 py-5">
      <div className="flex items-center gap-3"><span className="flex size-9 items-center justify-center rounded-lg bg-brand-50 text-brand-700"><Truck className="size-4" /></span><div><h2 className="text-sm font-bold text-brand-900">Free-Kick planning</h2><p className="mt-1 text-[11px] text-slate-400">Aparte principal · uitsluitend aggregaten</p></div></div>
    </div>
    <div className="p-5">
      {notice && <div role={notice.tone === "error" ? "alert" : "status"} className={`mb-4 flex items-start gap-2 rounded-lg border p-3 text-[11px] leading-5 ${notice.tone === "error" ? "border-red-100 bg-red-50 text-danger" : "border-emerald-100 bg-emerald-50 text-success"}`}>{notice.tone === "error" ? <AlertTriangle className="mt-0.5 size-4 shrink-0" /> : <Check className="mt-0.5 size-4 shrink-0" />}{notice.text}</div>}

      {oneTimeToken && <div className="mb-5 rounded-xl border border-amber-200 bg-amber-50 p-4"><div className="flex items-start justify-between gap-3"><div><p className="text-xs font-bold text-amber-900">Eenmalige toegangssleutel</p><p className="mt-1 text-[10px] leading-4 text-amber-800">De sleutel wordt niet opgeslagen of opnieuw getoond. Deel hem buiten e-mailtemplates en plak hem nooit in een URL.</p></div><button type="button" aria-label="Sleutel verbergen" onClick={() => setOneTimeToken(null)} className="flex size-9 shrink-0 items-center justify-center rounded-lg hover:bg-amber-100"><X className="size-4" /></button></div><code className="mt-3 block overflow-x-auto rounded-lg bg-white p-3 text-[11px] text-brand-900">{oneTimeToken}</code><button type="button" onClick={() => void copyToken()} className="mt-3 inline-flex h-9 items-center gap-2 rounded-lg bg-brand-700 px-3 text-[11px] font-bold text-white"><Clipboard className="size-3.5" />Kopiëren</button></div>}

      <form onSubmit={create} className="rounded-xl border border-brand-100 bg-brand-50/50 p-4">
        <p className="text-xs font-bold text-brand-900">Nieuwe leverancierstoegang</p>
        <label className="mt-3 block text-[11px] font-semibold text-ink">Interne naam<input className={inputClass} value={displayName} onChange={(event) => setDisplayName(event.target.value)} minLength={2} maxLength={120} required /></label>
        <SeasonChecks seasons={workspace?.seasons ?? []} selected={newSeasonIds} onChange={setNewSeasonIds} />
        <button type="submit" disabled={busy !== null || newSeasonIds.length === 0} className="mt-4 inline-flex h-10 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-bold text-white disabled:opacity-50">{busy === "create" ? <Loader2 className="size-4 animate-spin" /> : <KeyRound className="size-4" />}Sleutel aanmaken</button>
      </form>

      <div className="mt-5 flex items-center justify-between"><p className="text-[10px] font-bold uppercase tracking-[0.12em] text-slate-400">Bestaande toegang</p><button type="button" onClick={() => void load()} disabled={loading} aria-label="Leverancierstoegang vernieuwen" className="flex size-9 items-center justify-center rounded-lg text-brand-700 hover:bg-brand-50 disabled:opacity-50"><RefreshCw className={`size-4 ${loading ? "animate-spin" : ""}`} /></button></div>
      {!loading && workspace?.principals.length === 0 && <p className="mt-3 rounded-lg bg-slate-50 p-4 text-[11px] leading-5 text-slate-500">Er is nog geen leverancierstoegang. Er worden geen standaardaccounts of sleutels aangemaakt.</p>}
      <div className="mt-3 space-y-3">{workspace?.principals.map((principal) => <form key={`${principal.id}:${principal.updatedAt}`} onSubmit={(event) => event.preventDefault()} className="rounded-xl border border-line p-4">
        <div className="flex items-start justify-between gap-3"><div><p className="text-xs font-bold text-brand-900">{principal.displayName}</p><p className="mt-1 text-[10px] text-slate-400">Sleutel v{principal.tokenVersion} · {principal.activeSessions} actieve sessie(s){principal.lastUsedAt ? ` · laatst ${new Date(principal.lastUsedAt).toLocaleDateString("nl-NL")}` : ""}</p></div><span className={`rounded-full px-2 py-1 text-[9px] font-bold uppercase ${principal.active ? "bg-emerald-50 text-success" : "bg-slate-100 text-slate-500"}`}>{principal.active ? "Actief" : "Uit"}</span></div>
        <SeasonChecks seasons={workspace.seasons} selected={principal.seasonIds} name="seasonIds" />
        <label className="mt-3 block text-[11px] font-semibold text-ink">Reden voor wijziging<input name="reason" className={inputClass} minLength={4} maxLength={500} placeholder="Verplicht bij opslaan, roteren of intrekken" required /></label>
        <div className="mt-3 grid gap-2 sm:grid-cols-3">
          <button type="button" onClick={(event) => void manage(principal, event.currentTarget.form!, "set_seasons")} disabled={busy !== null} className="inline-flex h-9 items-center justify-center gap-1.5 rounded-lg border border-brand-200 text-[10px] font-bold text-brand-700 disabled:opacity-50"><Save className="size-3.5" />Seizoenen</button>
          <button type="button" onClick={(event) => void manage(principal, event.currentTarget.form!, "rotate")} disabled={busy !== null} className="inline-flex h-9 items-center justify-center gap-1.5 rounded-lg border border-brand-200 text-[10px] font-bold text-brand-700 disabled:opacity-50"><RefreshCw className="size-3.5" />Roteren</button>
          <button type="button" onClick={(event) => void manage(principal, event.currentTarget.form!, "disable")} disabled={busy !== null || !principal.active} className="inline-flex h-9 items-center justify-center gap-1.5 rounded-lg border border-red-200 text-[10px] font-bold text-danger disabled:opacity-50"><Power className="size-3.5" />Intrekken</button>
        </div>
      </form>)}</div>
    </div>
  </section>;
}

function SeasonChecks({
  seasons,
  selected,
  onChange,
  name,
}: {
  seasons: Workspace["seasons"];
  selected: string[];
  onChange?: (ids: string[]) => void;
  name?: string;
}) {
  return <fieldset className="mt-3"><legend className="text-[11px] font-semibold text-ink">Open seizoenen</legend><div className="mt-2 space-y-2">{seasons.map((season) => <label key={season.id} className="flex items-center gap-2 text-[11px] text-slate-600"><input type="checkbox" name={name} value={season.id} defaultChecked={onChange ? undefined : selected.includes(season.id)} checked={onChange ? selected.includes(season.id) : undefined} onChange={onChange ? (event) => onChange(event.target.checked ? [...selected, season.id] : selected.filter((id) => id !== season.id)) : undefined} className="size-4 accent-brand-700" />{season.name}</label>)}</div></fieldset>;
}
