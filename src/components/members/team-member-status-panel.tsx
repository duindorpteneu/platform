"use client";

import { AlertTriangle, CheckCircle2, Loader2, UsersRound } from "lucide-react";
import { useRouter } from "next/navigation";
import { useState } from "react";
import type { TeamMemberStatusResponse } from "@/lib/member-overview-contract";

type Notice = { tone: "error" | "success"; text: string } | null;
const fieldClass = "h-10 w-full rounded-lg border border-line bg-white px-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100 disabled:bg-slate-50 disabled:text-slate-400";

async function requestTeamStatus(body: unknown) {
  const response = await fetch("/api/members/team-status", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" },
    body: JSON.stringify(body),
  });
  const payload = await response.json() as TeamMemberStatusResponse & { error?: string };
  if (!response.ok) throw new Error(payload.error ?? "De teamstatus kon niet worden verwerkt.");
  return payload;
}

export function TeamMemberStatusPanel({ teams, initialTeam, disabled }: { teams: string[]; initialTeam?: string; disabled: boolean }) {
  const router = useRouter();
  const [team, setTeam] = useState(initialTeam && teams.includes(initialTeam) ? initialTeam : "");
  const [active, setActive] = useState(false);
  const [reason, setReason] = useState("");
  const [preview, setPreview] = useState<TeamMemberStatusResponse | null>(null);
  const [notice, setNotice] = useState<Notice>(null);
  const [busy, setBusy] = useState(false);

  function invalidate() {
    setPreview(null);
    setNotice(null);
  }

  async function run(commit: boolean) {
    setBusy(true);
    setNotice(null);
    try {
      const result = await requestTeamStatus({ team, active, reason: reason || undefined, previewToken: commit ? preview?.previewToken : undefined, commit });
      setPreview(result);
      if (commit) {
        setNotice({ tone: "success", text: `${result.changedMembers} leden in ${result.team} zijn ${active ? "actief" : "inactief"} gemaakt. ${result.unchangedMembers} waren al ongewijzigd.` });
        router.refresh();
      }
    } catch (error) {
      setNotice({ tone: "error", text: error instanceof Error ? error.message : "De teamstatus kon niet worden verwerkt." });
    } finally {
      setBusy(false);
    }
  }

  return <section className="rounded-xl border border-line bg-white p-5 shadow-card">
    <div className="flex items-start gap-3"><span className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-brand-50 text-brand-700"><UsersRound className="size-4" /></span><div><h2 className="text-sm font-bold text-brand-900">Teamstatus in bulk</h2><p className="mt-1 text-xs leading-5 text-slate-500">Activeer of deactiveer alle leden van één team. Bestellingen, betalingen en historie blijven behouden.</p></div></div>
    <fieldset disabled={disabled || busy || teams.length === 0} className="mt-5 space-y-3">
      <label className="block text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400">Team<select value={team} onChange={(event) => { setTeam(event.target.value); invalidate(); }} className={"mt-2 " + fieldClass}><option value="">Kies een team</option>{teams.map((option) => <option key={option} value={option}>{option}</option>)}</select></label>
      <label className="block text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400">Nieuwe status<select value={active ? "active" : "inactive"} onChange={(event) => { setActive(event.target.value === "active"); invalidate(); }} className={"mt-2 " + fieldClass}><option value="inactive">Inactief</option><option value="active">Actief</option></select></label>
      <label className="block text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400">Reden<input value={reason} onChange={(event) => { setReason(event.target.value); invalidate(); }} maxLength={240} placeholder="Bijv. teamindeling nieuw seizoen" className={"mt-2 " + fieldClass} /></label>
    </fieldset>

    {preview && !preview.committed && <div className="mt-4 rounded-lg border border-brand-100 bg-brand-50 p-4"><p className="text-xs font-bold text-brand-900">Controle gereed voor {preview.team}</p><p className="mt-1 text-[11px] leading-5 text-brand-700">{preview.changedMembers} van {preview.totalMembers} leden worden {active ? "actief" : "inactief"}. {preview.unchangedMembers} leden hebben deze status al.</p></div>}
    {notice && <div role={notice.tone === "error" ? "alert" : "status"} className={"mt-4 flex gap-2 rounded-lg border p-3 text-[11px] leading-5 " + (notice.tone === "error" ? "border-red-100 bg-red-50 text-danger" : "border-emerald-100 bg-emerald-50 text-success")}>{notice.tone === "error" ? <AlertTriangle className="mt-0.5 size-3.5 shrink-0" /> : <CheckCircle2 className="mt-0.5 size-3.5 shrink-0" />}{notice.text}</div>}

    <div className="mt-4 grid gap-2 sm:grid-cols-2 xl:grid-cols-1">
      <button type="button" disabled={disabled || busy || !team} onClick={() => run(false)} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-brand-200 bg-white px-3 text-xs font-semibold text-brand-700 hover:border-brand-500 disabled:cursor-not-allowed disabled:opacity-50">{busy ? <Loader2 className="size-4 animate-spin" /> : null}Wijzigingen controleren</button>
      <button type="button" disabled={disabled || busy || !preview?.previewToken || preview.committed || preview.changedMembers === 0 || reason.trim().length < 3} onClick={() => run(true)} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-3 text-xs font-semibold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:opacity-50"><CheckCircle2 className="size-4" /> Definitief uitvoeren</button>
    </div>
    {disabled && <p className="mt-3 text-[10px] leading-4 text-amber-700">Een open actief seizoen is verplicht voor deze actie.</p>}
  </section>;
}
