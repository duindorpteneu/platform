"use client";

import { AlertTriangle, KeyRound, Loader2, ShieldCheck } from "lucide-react";
import { FormEvent, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabaseBrowserClient } from "@/lib/supabase/client";
import { parseStaffInvitationFragment } from "@/lib/staff-invitation";

export function StaffSetPasswordForm() {
  const router = useRouter();
  const [password, setPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [initializing, setInitializing] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;

    async function acceptInvitation() {
      const supabase = getSupabaseBrowserClient();
      if (!supabase) {
        if (active) { setError("Wachtwoord instellen is in deze omgeving niet geconfigureerd."); setInitializing(false); }
        return;
      }

      const { data: existing } = await supabase.auth.getUser();
      if (existing.user) {
        if (active) setInitializing(false);
        return;
      }

      const invitation = parseStaffInvitationFragment(window.location.hash);
      window.history.replaceState(null, "", window.location.pathname + window.location.search);
      if (!invitation) {
        if (active) { setError("Deze uitnodigingslink is ongeldig of verlopen."); setInitializing(false); }
        return;
      }

      const { error: sessionError } = await supabase.auth.setSession({ access_token: invitation.accessToken, refresh_token: invitation.refreshToken });
      if (active) {
        if (sessionError) setError("Deze uitnodigingslink is ongeldig of verlopen.");
        setInitializing(false);
      }
    }

    void acceptInvitation();
    return () => { active = false; };
  }, []);

  async function submit(event: FormEvent) {
    event.preventDefault();
    setError(null);
    if (password.length < 16) {
      setError("Kies een wachtwoord van minimaal 16 tekens.");
      return;
    }
    if (password !== confirmation) {
      setError("De wachtwoorden zijn niet gelijk.");
      return;
    }

    setBusy(true);
    const supabase = getSupabaseBrowserClient();
    if (!supabase) {
      setError("Wachtwoord instellen is in deze omgeving niet geconfigureerd.");
      setBusy(false);
      return;
    }
    const { data: userData } = await supabase.auth.getUser();
    if (!userData.user) {
      router.replace("/staff/login?uitnodiging=ongeldig");
      return;
    }
    const { error: updateError } = await supabase.auth.updateUser({ password });
    if (updateError) {
      setError("Het wachtwoord kon niet veilig worden ingesteld. Open de uitnodigingslink opnieuw.");
      setBusy(false);
      return;
    }
    router.replace("/staff/mfa");
    router.refresh();
  }

  if (initializing) return <div className="mt-7 flex min-h-24 items-center justify-center text-sm text-slate-500"><Loader2 className="mr-2 size-4 animate-spin" /> Uitnodiging controleren…</div>;

  return (
    <form onSubmit={(event) => void submit(event)}>
      {error && <div role="alert" className="mt-6 flex gap-2 rounded-xl border border-red-100 bg-red-50 p-3 text-xs text-danger"><AlertTriangle className="size-4 shrink-0" />{error}</div>}
      {!error && <><label htmlFor="new-password" className="mt-7 block text-xs font-semibold text-ink">Nieuw wachtwoord</label>
      <div className="relative mt-2"><KeyRound className="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" /><input id="new-password" type="password" autoComplete="new-password" minLength={16} required value={password} onChange={(event) => setPassword(event.target.value)} className="h-11 w-full rounded-lg border border-line pl-10 pr-3 text-sm outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></div>
      <label htmlFor="confirm-password" className="mt-4 block text-xs font-semibold text-ink">Herhaal wachtwoord</label>
      <div className="relative mt-2"><KeyRound className="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" /><input id="confirm-password" type="password" autoComplete="new-password" minLength={16} required value={confirmation} onChange={(event) => setConfirmation(event.target.value)} className="h-11 w-full rounded-lg border border-line pl-10 pr-3 text-sm outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></div>
      <button disabled={busy} className="mt-5 flex h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 text-sm font-semibold text-white hover:bg-brand-900 disabled:bg-slate-300">{busy ? <Loader2 className="size-4 animate-spin" /> : <ShieldCheck className="size-4" />} Wachtwoord opslaan</button></>}
    </form>
  );
}
