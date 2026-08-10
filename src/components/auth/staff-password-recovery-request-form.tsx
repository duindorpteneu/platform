"use client";

import { AlertTriangle, ArrowLeft, Loader2, Mail, Send } from "lucide-react";
import Link from "next/link";
import { type FormEvent, useState } from "react";

export function StaffPasswordRecoveryRequestForm() {
  const [email, setEmail] = useState("");
  const [busy, setBusy] = useState(false);
  const [sent, setSent] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const response = await fetch("/api/staff-auth/password-recovery", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" },
        body: JSON.stringify({ email: email.trim().toLowerCase() }),
      });
      if (!response.ok) throw new Error("RECOVERY_REQUEST_FAILED");
      setSent(true);
    } catch {
      setError("Het herstelverzoek kon niet worden verwerkt. Probeer het later opnieuw.");
    } finally {
      setBusy(false);
    }
  }

  if (sent) {
    return <div><div role="status" className="mt-6 rounded-xl border border-emerald-100 bg-emerald-50 p-4 text-xs leading-5 text-success">Als dit e-mailadres bij een medewerkersaccount hoort, ontvang je een herstellink. Open die link bij voorkeur op hetzelfde apparaat.</div><Link href="/staff/login" className="mt-5 flex h-10 items-center justify-center gap-2 text-xs font-semibold text-brand-700 hover:text-brand-900"><ArrowLeft className="size-4" />Terug naar inloggen</Link></div>;
  }

  return <form onSubmit={(event) => void submit(event)}>
    {error && <div role="alert" className="mt-6 flex gap-2 rounded-xl border border-red-100 bg-red-50 p-3 text-xs text-danger"><AlertTriangle className="size-4 shrink-0" />{error}</div>}
    <label htmlFor="staff-recovery-email" className="mt-7 block text-xs font-semibold text-ink">E-mailadres</label>
    <div className="relative mt-2"><Mail className="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" /><input id="staff-recovery-email" type="email" autoComplete="email" required value={email} onChange={(event) => setEmail(event.target.value)} className="h-11 w-full rounded-lg border border-line pl-10 pr-3 text-sm outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></div>
    <button disabled={busy} className="mt-5 flex h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 text-sm font-semibold text-white hover:bg-brand-900 disabled:bg-slate-300">{busy ? <Loader2 className="size-4 animate-spin" /> : <Send className="size-4" />}Herstellink aanvragen</button>
    <Link href="/staff/login" className="mt-4 flex h-10 items-center justify-center gap-2 text-xs font-semibold text-slate-500 hover:text-brand-900"><ArrowLeft className="size-4" />Terug naar inloggen</Link>
  </form>;
}
