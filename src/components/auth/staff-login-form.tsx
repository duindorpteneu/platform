"use client";

import { AlertTriangle, ArrowRight, Loader2, LockKeyhole, Mail } from "lucide-react";
import { FormEvent, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabaseBrowserClient } from "@/lib/supabase/client";
import { resolveStaffLandingPath } from "@/lib/staff-session";

export function StaffLoginForm() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError(null);

    const supabase = getSupabaseBrowserClient();
    if (!supabase) {
      setError("Medewerkerslogin is lokaal nog niet geconfigureerd.");
      setBusy(false);
      return;
    }

    const { error: signInError } = await supabase.auth.signInWithPassword({ email: email.trim().toLowerCase(), password });
    if (signInError) {
      setError("E-mailadres of wachtwoord is niet geldig.");
      setBusy(false);
      return;
    }

    const { data: assurance } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
    if (assurance?.currentLevel !== "aal2") {
      router.replace("/staff/mfa");
      router.refresh();
      return;
    }

    const landingPath = await resolveStaffLandingPath();
    if (!landingPath) {
      setError("Je account heeft geen actief medewerkersprofiel. Vraag een beheerder om het account te activeren.");
      setBusy(false);
      return;
    }
    router.replace(landingPath);
    router.refresh();
  }

  return (
    <form onSubmit={(event) => void submit(event)}>
      {error && <div role="alert" className="mt-6 flex gap-2 rounded-xl border border-red-100 bg-red-50 p-3 text-xs text-danger"><AlertTriangle className="size-4 shrink-0" />{error}</div>}
      <label htmlFor="staff-email" className="mt-7 block text-xs font-semibold text-ink">E-mailadres</label>
      <div className="relative mt-2"><Mail className="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" /><input id="staff-email" type="email" autoComplete="username" required value={email} onChange={(event) => setEmail(event.target.value)} placeholder="naam@duindorpsv.nl" className="h-11 w-full rounded-lg border border-line pl-10 pr-3 text-sm outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></div>
      <label htmlFor="staff-password" className="mt-4 block text-xs font-semibold text-ink">Wachtwoord</label>
      <div className="relative mt-2"><LockKeyhole className="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" /><input id="staff-password" type="password" autoComplete="current-password" required minLength={12} value={password} onChange={(event) => setPassword(event.target.value)} className="h-11 w-full rounded-lg border border-line pl-10 pr-3 text-sm outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></div>
      <button disabled={busy} className="mt-5 flex h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 text-sm font-semibold text-white hover:bg-brand-900 disabled:bg-slate-300">{busy ? <Loader2 className="size-4 animate-spin" /> : <ArrowRight className="size-4" />} Inloggen</button>
    </form>
  );
}
