"use client";

import { AlertTriangle, ArrowRight, Check, CheckCircle2, Loader2, Pencil, Save, Users, X } from "lucide-react";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import type { MemberDetailResponse } from "@/lib/member-overview-contract";
import type { MemberFamilyEmailPreflight } from "@/lib/member-profile-contract";

type FormState = {
  firstName: string;
  insertion: string;
  lastName: string;
  email: string;
  dateOfBirth: string;
  gender: MemberDetailResponse["gender"];
  team: string;
  reason: string;
};

function formFrom(detail: MemberDetailResponse): FormState {
  return {
    firstName: detail.firstName,
    insertion: detail.insertion ?? "",
    lastName: detail.lastName,
    email: detail.email ?? "",
    dateOfBirth: detail.dateOfBirth ?? "",
    gender: detail.gender,
    team: detail.team === "Onbekend team" ? "" : detail.team,
    reason: "",
  };
}

const fieldClass = "mt-1 h-10 w-full rounded-lg border border-line bg-white px-3 text-xs text-ink outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100 disabled:bg-slate-50";

export function MemberProfileEditor({ detail }: { detail: MemberDetailResponse }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState<FormState>(() => formFrom(detail));
  const [requestId, setRequestId] = useState(() => crypto.randomUUID());
  const [saving, setSaving] = useState(false);
  const [preflight, setPreflight] = useState<MemberFamilyEmailPreflight | null>(null);
  const [notice, setNotice] = useState<{ tone: "success" | "error"; text: string } | null>(null);

  useEffect(() => {
    setForm(formFrom(detail));
    setPreflight(null);
  }, [detail]);

  function change<K extends keyof FormState>(field: K, value: FormState[K]) {
    setForm((current) => ({ ...current, [field]: value }));
    setPreflight(null);
    setNotice(null);
  }

  function close() {
    setOpen(false);
    setForm(formFrom(detail));
    setPreflight(null);
    setNotice(null);
    setRequestId(crypto.randomUUID());
  }

  async function apply(familyRevision: string | null) {
    setSaving(true);
    setNotice(null);
    try {
      const response = await fetch("/api/members/profile", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Duindorp-CSRF": "same-origin",
        },
        body: JSON.stringify({
          memberId: detail.id,
          memberSeasonId: detail.memberSeasonId,
          ...form,
          revision: detail.profileRevision,
          familyRevision,
          requestId,
        }),
      });
      const payload = await response.json() as { error?: string };
      if (!response.ok) throw new Error(payload.error ?? "De lidgegevens konden niet worden opgeslagen.");
      setNotice({
        tone: "success",
        text: familyRevision
          ? "Het gezins-e-mailadres en de portaltoegang zijn veilig overgezet."
          : "De lidgegevens zijn opgeslagen en geaudit.",
      });
      setRequestId(crypto.randomUUID());
      setPreflight(null);
      setOpen(false);
      router.refresh();
    } catch (error) {
      setNotice({
        tone: "error",
        text: error instanceof Error ? error.message : "De lidgegevens konden niet worden opgeslagen.",
      });
    } finally {
      setSaving(false);
    }
  }

  async function save(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const currentEmail = detail.email?.trim().toLowerCase() ?? "";
    const newEmail = form.email.trim().toLowerCase();
    if (newEmail === currentEmail || newEmail === "") {
      await apply(null);
      return;
    }
    setSaving(true);
    setNotice(null);
    try {
      const response = await fetch("/api/members/profile/email-preflight", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Duindorp-CSRF": "same-origin",
        },
        body: JSON.stringify({
          memberId: detail.id,
          memberSeasonId: detail.memberSeasonId,
          email: form.email,
          revision: detail.profileRevision,
        }),
      });
      const payload = await response.json() as MemberFamilyEmailPreflight & { error?: string };
      if (!response.ok) throw new Error(payload.error ?? "De e-mailwijziging kon niet worden gecontroleerd.");
      if (payload.portalAccessActive) {
        setPreflight(payload);
      } else {
        await apply(null);
      }
    } catch (error) {
      setNotice({
        tone: "error",
        text: error instanceof Error ? error.message : "De e-mailwijziging kon niet worden gecontroleerd.",
      });
    } finally {
      setSaving(false);
    }
  }

  if (!open) {
    return <div className="mt-4">
      {notice && <div role={notice.tone === "error" ? "alert" : "status"} className={`mb-3 flex gap-2 rounded-lg border p-3 text-xs ${notice.tone === "error" ? "border-red-100 bg-red-50 text-danger" : "border-emerald-100 bg-emerald-50 text-success"}`}>{notice.tone === "error" ? <AlertTriangle className="size-4 shrink-0" /> : <CheckCircle2 className="size-4 shrink-0" />}{notice.text}</div>}
      <button type="button" onClick={() => setOpen(true)} className="inline-flex h-10 w-full items-center justify-center gap-2 rounded-lg border border-brand-200 px-4 text-xs font-semibold text-brand-800 hover:bg-brand-50"><Pencil className="size-4" /> Lid bewerken</button>
    </div>;
  }

  return <form className="mt-4 space-y-3 rounded-lg border border-brand-100 bg-brand-50/40 p-4" onSubmit={(event) => void save(event)}>
    <div className="flex items-center justify-between gap-3">
      <div><h4 className="text-xs font-bold text-brand-900">Lidgegevens bewerken</h4><p className="mt-1 text-[10px] leading-4 text-slate-500">Wijzigingen gelden voor het actieve seizoen; historische seizoenen blijven intact.</p></div>
      <button type="button" onClick={close} aria-label="Bewerken sluiten" className="flex size-8 items-center justify-center rounded-lg border border-line bg-white text-slate-500"><X className="size-4" /></button>
    </div>
    <div className="grid grid-cols-2 gap-3">
      <label className="col-span-2 text-[11px] font-semibold text-slate-600">Voornaam *<input required maxLength={120} value={form.firstName} onChange={(event) => change("firstName", event.target.value)} className={fieldClass} /></label>
      <label className="text-[11px] font-semibold text-slate-600">Tussenvoegsel<input maxLength={80} value={form.insertion} onChange={(event) => change("insertion", event.target.value)} className={fieldClass} /></label>
      <label className="text-[11px] font-semibold text-slate-600">Achternaam *<input required maxLength={120} value={form.lastName} onChange={(event) => change("lastName", event.target.value)} className={fieldClass} /></label>
      <label className="col-span-2 text-[11px] font-semibold text-slate-600">E-mailadres ouder<input type="email" maxLength={320} value={form.email} onChange={(event) => change("email", event.target.value)} className={fieldClass} /></label>
      <label className="text-[11px] font-semibold text-slate-600">Geboortedatum<input type="date" min="1900-01-01" max={new Date().toISOString().slice(0, 10)} value={form.dateOfBirth} onChange={(event) => change("dateOfBirth", event.target.value)} className={fieldClass} /></label>
      <label className="text-[11px] font-semibold text-slate-600">Geslacht<select value={form.gender} onChange={(event) => change("gender", event.target.value as FormState["gender"])} className={fieldClass}><option value="unknown">Onbekend</option><option value="male">Man/jongen</option><option value="female">Vrouw/meisje</option><option value="other">Anders</option></select></label>
      <label className="col-span-2 text-[11px] font-semibold text-slate-600">Team actief seizoen<input maxLength={120} value={form.team} onChange={(event) => change("team", event.target.value)} className={fieldClass} /></label>
      <label className="col-span-2 text-[11px] font-semibold text-slate-600">Reden *<textarea required minLength={3} maxLength={500} rows={3} value={form.reason} onChange={(event) => change("reason", event.target.value)} placeholder="Bijvoorbeeld: correctie op verzoek van ouder" className="mt-1 w-full rounded-lg border border-line bg-white px-3 py-2 text-xs text-ink outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></label>
    </div>
    {preflight ? <div className="space-y-3 rounded-lg border border-brand-200 bg-white p-4" role="status">
      <div className="flex items-center gap-2"><Users className="size-4 text-brand-700" /><p className="text-xs font-bold text-brand-900">Portaaltoegang actief</p></div>
      <div className="flex flex-wrap items-center gap-2 text-xs"><span className="break-all text-slate-500">{preflight.currentPortalEmail}</span><ArrowRight className="size-3.5 text-brand-500" /><span className="break-all font-bold text-brand-900">{preflight.newEmail}</span></div>
      <p className="text-[11px] leading-5 text-slate-600">Dit account geeft toegang tot {preflight.affectedMemberCount} {preflight.affectedMemberCount === 1 ? "kind" : "kinderen"}. Alle onderstaande leden krijgen hetzelfde nieuwe e-mailadres en hun portaltoegang wordt samen overgezet.</p>
      {preflight.targetAccountReused && <p className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-[10px] leading-4 text-amber-900">Het nieuwe e-mailadres hoort al bij een bestaand portaalaccount. Bestaande toegang op dat account blijft behouden.</p>}
      <ul className="space-y-2">{preflight.affectedChildren.map((child) => <li key={child.memberSeasonId} className="flex items-start gap-2 rounded-lg bg-brand-50 px-3 py-2 text-[11px] text-brand-900"><Check className="mt-0.5 size-3.5 shrink-0" /><span><strong>{child.memberName}</strong> — {child.team}</span></li>)}</ul>
      {preflight.transferRequired && <p className="rounded-lg bg-emerald-50 p-3 text-[10px] leading-4 text-emerald-900">Na de wijziging wordt de bestaande bevestigingsmail voor portaltoegang naar {preflight.newEmail} gestuurd.</p>}
    </div> : <div className="rounded-lg border border-slate-200 bg-slate-50 p-3 text-[10px] leading-4 text-slate-600">Bij een actief gedeeld ouderaccount controleert het systeem eerst welke gekoppelde kinderen gezinsbreed moeten worden overgezet.</div>}
    {notice?.tone === "error" && <div role="alert" className="flex gap-2 rounded-lg bg-red-50 p-3 text-xs text-danger"><AlertTriangle className="size-4 shrink-0" />{notice.text}</div>}
    <div className="flex gap-2"><button type="button" onClick={close} disabled={saving} className="h-10 flex-1 rounded-lg border border-line bg-white px-3 text-xs font-semibold text-slate-600">Annuleren</button>{preflight ? <button type="button" onClick={() => void apply(preflight.familyRevision)} disabled={saving} className="inline-flex min-h-10 flex-1 items-center justify-center gap-2 rounded-lg bg-brand-700 px-3 py-2 text-xs font-semibold text-white hover:bg-brand-900 disabled:opacity-50">{saving ? <Loader2 className="size-4 animate-spin" /> : <Users className="size-4" />} E-mailadres + portaltoegang voor {preflight.affectedMemberCount} {preflight.affectedMemberCount === 1 ? "kind" : "kinderen"} wijzigen</button> : <button type="submit" disabled={saving} className="inline-flex h-10 flex-1 items-center justify-center gap-2 rounded-lg bg-brand-700 px-3 text-xs font-semibold text-white hover:bg-brand-900 disabled:opacity-50">{saving ? <Loader2 className="size-4 animate-spin" /> : <Save className="size-4" />} Opslaan</button>}</div>
  </form>;
}
