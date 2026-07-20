"use client";

import { AlertTriangle, CheckCircle2, Loader2, Power, RotateCcw } from "lucide-react";
import { type FormEvent, useState } from "react";
import { useRouter } from "next/navigation";

export function MemberStatusAction({ memberId, active }: { memberId: string; active: boolean }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const nextActive = !active;

  async function submit(event: FormEvent) {
    event.preventDefault();
    setSaving(true); setError(null);
    try {
      const response = await fetch("/api/members/status", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" },
        body: JSON.stringify({ memberId, active: nextActive, reason }),
      });
      const payload = await response.json() as { error?: string };
      if (!response.ok) throw new Error(payload.error ?? "De lidstatus kon niet worden opgeslagen.");
      setOpen(false); setReason("");
      router.refresh();
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : "De lidstatus kon niet worden opgeslagen.");
    } finally { setSaving(false); }
  }

  if (!open) return <button type="button" onClick={() => setOpen(true)} className={"mt-4 inline-flex h-9 w-full items-center justify-center gap-2 rounded-lg border px-3 text-xs font-bold " + (active ? "border-red-100 text-danger hover:bg-red-50" : "border-emerald-200 text-success hover:bg-emerald-50")}>{active ? <Power className="size-3.5" /> : <RotateCcw className="size-3.5" />}{active ? "Lid inactief maken" : "Lid weer activeren"}</button>;

  return <form onSubmit={submit} className="mt-4 rounded-lg border border-line bg-slate-50 p-3">
    <div className="flex items-start gap-2">{active ? <AlertTriangle className="mt-0.5 size-4 shrink-0 text-warning" /> : <CheckCircle2 className="mt-0.5 size-4 shrink-0 text-success" />}<p className="text-[11px] leading-5 text-slate-600">{active ? "Nieuwe bestellingen en betalingen worden geblokkeerd. Bestaande historie blijft bewaard." : "Dit lid wordt weer beschikbaar voor nieuwe bestellingen en betalingen."}</p></div>
    <label className="mt-3 block text-[11px] font-semibold text-ink">Reden<textarea value={reason} onChange={(event) => setReason(event.target.value)} minLength={3} maxLength={240} required rows={3} className="mt-2 w-full resize-none rounded-lg border border-line bg-white p-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" placeholder={active ? "Bijv. afgemeld voor dit seizoen" : "Bijv. opnieuw aangemeld"} /></label>
    {error && <p role="alert" className="mt-2 text-[11px] text-danger">{error}</p>}
    <div className="mt-3 flex gap-2"><button type="button" onClick={() => { setOpen(false); setError(null); }} disabled={saving} className="h-9 flex-1 rounded-lg border border-line bg-white text-xs font-semibold text-slate-600">Annuleren</button><button type="submit" disabled={saving || reason.trim().length < 3} className={"inline-flex h-9 flex-1 items-center justify-center gap-2 rounded-lg text-xs font-bold text-white disabled:opacity-50 " + (active ? "bg-red-600 hover:bg-red-700" : "bg-emerald-600 hover:bg-emerald-700")}>{saving && <Loader2 className="size-3.5 animate-spin" />}{active ? "Inactiveren" : "Activeren"}</button></div>
  </form>;
}
