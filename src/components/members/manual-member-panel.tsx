"use client";

import { AlertTriangle, CheckCircle2, Loader2, UserPlus } from "lucide-react";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { manualMemberPreflightSchema, type ManualMemberPreflight } from "@/lib/manual-member-contract";

const emptyForm = {
  externalId: "",
  firstName: "",
  insertion: "",
  lastName: "",
  email: "",
  dateOfBirth: "",
  gender: "unknown",
  team: "",
};

const reasonLabels = {
  external_id: "zelfde relatienummer",
  name_date_of_birth: "zelfde naam en geboortedatum",
  name_email: "zelfde naam en e-mail",
  name_only: "dezelfde naam",
} as const;

export function ManualMemberPanel() {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [form, setForm] = useState(emptyForm);
  const [clientRequestId, setClientRequestId] = useState(() => crypto.randomUUID());
  const [preflight, setPreflight] = useState<ManualMemberPreflight | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  function change(field: keyof typeof emptyForm, value: string) {
    setForm((current) => ({ ...current, [field]: value }));
    setPreflight(null);
    setError(null);
  }

  async function submit(allowPotentialDuplicate = false) {
    setBusy(true);
    setError(null);
    setSuccess(null);
    try {
      const response = await fetch("/api/members/manual", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Duindorp-CSRF": "same-origin",
        },
        body: JSON.stringify({
          ...form,
          clientRequestId,
          allowPotentialDuplicate,
          expectedFingerprint: allowPotentialDuplicate ? preflight?.fingerprint ?? null : null,
        }),
      });
      const body: unknown = await response.json();
      if (!response.ok) {
        if (body && typeof body === "object" && "preflight" in body) {
          const parsed = manualMemberPreflightSchema.safeParse(body.preflight);
          if (parsed.success) setPreflight(parsed.data);
        }
        const message = body && typeof body === "object" && "error" in body && typeof body.error === "string"
          ? body.error
          : "Het lid kon niet worden toegevoegd.";
        throw new Error(message);
      }
      setForm(emptyForm);
      setPreflight(null);
      setClientRequestId(crypto.randomUUID());
      setSuccess("Lid toegevoegd aan het actieve seizoen. Er is geen toegang, mail, bestelling of pakket aangemaakt.");
      router.refresh();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Het lid kon niet worden toegevoegd.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="rounded-xl border border-line bg-white p-5 shadow-card">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="text-base font-bold text-brand-900">Lid handmatig toevoegen</h2>
          <p className="mt-1 text-xs leading-5 text-slate-500">Voor een lid dat niet via Sportlink wordt geïmporteerd.</p>
        </div>
        <UserPlus className="size-5 shrink-0 text-brand-500" />
      </div>
      {!open ? (
        <button type="button" onClick={() => setOpen(true)} className="mt-5 inline-flex h-10 w-full items-center justify-center gap-2 rounded-lg border border-brand-200 px-4 text-xs font-semibold text-brand-800 hover:bg-brand-50">
          Formulier openen
        </button>
      ) : (
        <form className="mt-5 space-y-3" onSubmit={(event) => { event.preventDefault(); void submit(false); }}>
          <div className="grid grid-cols-2 gap-3">
            <label className="col-span-2 text-[11px] font-semibold text-slate-600">Voornaam *<input required value={form.firstName} onChange={(event) => change("firstName", event.target.value)} maxLength={120} className="mt-1 h-10 w-full rounded-lg border border-line px-3 text-xs" /></label>
            <label className="text-[11px] font-semibold text-slate-600">Tussenvoegsel<input value={form.insertion} onChange={(event) => change("insertion", event.target.value)} maxLength={80} className="mt-1 h-10 w-full rounded-lg border border-line px-3 text-xs" /></label>
            <label className="text-[11px] font-semibold text-slate-600">Achternaam *<input required value={form.lastName} onChange={(event) => change("lastName", event.target.value)} maxLength={120} className="mt-1 h-10 w-full rounded-lg border border-line px-3 text-xs" /></label>
            <label className="col-span-2 text-[11px] font-semibold text-slate-600">Sportlink-relatienummer<input value={form.externalId} onChange={(event) => change("externalId", event.target.value)} maxLength={120} className="mt-1 h-10 w-full rounded-lg border border-line px-3 text-xs" /></label>
            <label className="col-span-2 text-[11px] font-semibold text-slate-600">E-mailadres ouder<input type="email" value={form.email} onChange={(event) => change("email", event.target.value)} maxLength={320} className="mt-1 h-10 w-full rounded-lg border border-line px-3 text-xs" /></label>
            <label className="text-[11px] font-semibold text-slate-600">Geboortedatum<input type="date" value={form.dateOfBirth} onChange={(event) => change("dateOfBirth", event.target.value)} min="1900-01-01" max={new Date().toISOString().slice(0, 10)} className="mt-1 h-10 w-full rounded-lg border border-line px-3 text-xs" /></label>
            <label className="text-[11px] font-semibold text-slate-600">Geslacht<select value={form.gender} onChange={(event) => change("gender", event.target.value)} className="mt-1 h-10 w-full rounded-lg border border-line bg-white px-3 text-xs"><option value="unknown">Onbekend</option><option value="male">Man/jongen</option><option value="female">Vrouw/meisje</option><option value="other">Anders</option></select></label>
            <label className="col-span-2 text-[11px] font-semibold text-slate-600">Team<input value={form.team} onChange={(event) => change("team", event.target.value)} maxLength={120} className="mt-1 h-10 w-full rounded-lg border border-line px-3 text-xs" /></label>
          </div>

          {error && <div className="flex items-start gap-2 rounded-lg bg-red-50 p-3 text-[11px] leading-5 text-danger" role="alert"><AlertTriangle className="mt-0.5 size-4 shrink-0" />{error}</div>}
          {success && <div className="flex items-start gap-2 rounded-lg bg-emerald-50 p-3 text-[11px] leading-5 text-emerald-900" role="status"><CheckCircle2 className="mt-0.5 size-4 shrink-0" />{success}</div>}

          {preflight && preflight.candidates.length > 0 && (
            <div className="rounded-lg border border-amber-200 bg-amber-50 p-3">
              <p className="text-xs font-bold text-amber-950">Mogelijk bestaand lid</p>
              <ul className="mt-2 space-y-2 text-[11px] leading-5 text-amber-900">
                {preflight.candidates.map((candidate) => <li key={candidate.memberId}><strong>{candidate.memberName}</strong>{candidate.team ? ` · ${candidate.team}` : ""}<br />{candidate.reasons.map((reason) => reasonLabels[reason]).join(", ")}</li>)}
              </ul>
              {!preflight.candidates.some((candidate) => candidate.reasons.includes("external_id")) && (
                <button type="button" disabled={busy} onClick={() => void submit(true)} className="mt-3 inline-flex h-10 w-full items-center justify-center rounded-lg bg-amber-700 px-3 text-xs font-semibold text-white hover:bg-amber-800 disabled:opacity-50">Toch als nieuw lid toevoegen</button>
              )}
            </div>
          )}

          <p className="text-[10px] leading-4 text-slate-500">Alleen naam is verplicht. Mogelijke dubbelen worden nooit automatisch samengevoegd.</p>
          <div className="flex gap-2">
            <button type="button" onClick={() => { setOpen(false); setError(null); setPreflight(null); }} className="h-10 flex-1 rounded-lg border border-line px-3 text-xs font-semibold text-slate-600">Sluiten</button>
            <button type="submit" disabled={busy} className="inline-flex h-10 flex-1 items-center justify-center gap-2 rounded-lg bg-brand-700 px-3 text-xs font-semibold text-white hover:bg-brand-900 disabled:opacity-50">{busy && <Loader2 className="size-4 animate-spin" />} Toevoegen</button>
          </div>
        </form>
      )}
    </section>
  );
}
