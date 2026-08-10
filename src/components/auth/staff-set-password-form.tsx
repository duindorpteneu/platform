"use client";

import { AlertTriangle, KeyRound, Loader2, ShieldCheck } from "lucide-react";
import { FormEvent, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { getSupabaseBrowserClient } from "@/lib/supabase/client";
import { parseStaffInvitationFragment, parseStaffRecoveryFragment } from "@/lib/staff-invitation";

export function StaffSetPasswordForm({ mode = "invite" }: { mode?: "invite" | "recovery" }) {
  const router = useRouter();
  const [password, setPassword] = useState("");
  const [confirmation, setConfirmation] = useState("");
  const [factorId, setFactorId] = useState<string | null>(null);
  const [mfaCode, setMfaCode] = useState("");
  const [initializing, setInitializing] = useState(true);
  const [sessionReady, setSessionReady] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;

    async function acceptPasswordSession() {
      const passwordSession = mode === "invite"
        ? parseStaffInvitationFragment(window.location.hash)
        : parseStaffRecoveryFragment(window.location.hash);
      if (!passwordSession) {
        window.history.replaceState(null, "", window.location.pathname);
        if (active) {
          setError(mode === "invite" ? "Deze uitnodigingslink is ongeldig of verlopen." : "Deze herstellink is ongeldig of verlopen.");
          setInitializing(false);
        }
        return;
      }

      window.history.replaceState(null, "", window.location.pathname);
      const supabase = getSupabaseBrowserClient();
      if (!supabase) {
        if (active) { setError("Wachtwoord instellen is in deze omgeving niet geconfigureerd."); setInitializing(false); }
        return;
      }
      const { error: sessionError } = await supabase.auth.setSession({
        access_token: passwordSession.accessToken,
        refresh_token: passwordSession.refreshToken,
      });
      let factorError = false;
      if (!sessionError && mode === "recovery") {
        const factors = await supabase.auth.mfa.listFactors();
        factorError = Boolean(factors.error);
        if (!factorError && active) setFactorId(factors.data?.totp[0]?.id ?? null);
      }
      if (active) {
        if (sessionError || factorError) setError(mode === "invite" ? "Deze uitnodigingslink is ongeldig of verlopen." : "Deze herstellink kon niet veilig worden gecontroleerd.");
        else setSessionReady(true);
        setInitializing(false);
      }
    }

    void acceptPasswordSession();
    return () => { active = false; };
  }, [mode]);

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
    if (factorId && !/^\d{6}$/.test(mfaCode)) {
      setError("Voer de zescijferige code uit je authenticator-app in.");
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
    if (factorId) {
      const verification = await supabase.auth.mfa.challengeAndVerify({ factorId, code: mfaCode });
      if (verification.error) {
        setError("De verificatiecode is niet geldig of verlopen.");
        setBusy(false);
        return;
      }
    }
    const { error: updateError } = await supabase.auth.updateUser({ password });
    if (updateError) {
      setError(`Het wachtwoord kon niet veilig worden ingesteld. Open de ${mode === "invite" ? "uitnodigingslink" : "herstellink"} opnieuw.`);
      setBusy(false);
      return;
    }

    if (mode === "recovery") {
      const completion = await fetch("/api/staff-auth/password-changed", {
        method: "POST",
        headers: { "X-Duindorp-CSRF": "same-origin" },
      }).catch(() => null);
      if (!completion?.ok) {
        await supabase.auth.signOut({ scope: "global" });
        setError("Het wachtwoord is gewijzigd, maar bestaande sessies konden niet volledig worden ingetrokken. Neem contact op met een beheerder voordat je opnieuw inlogt.");
        setBusy(false);
        return;
      }
      await supabase.auth.signOut({ scope: "global" });
      window.location.assign("/staff/login?wachtwoord=gewijzigd");
      return;
    }
    router.replace("/staff/mfa");
    router.refresh();
  }

  if (initializing) return <div className="mt-7 flex min-h-24 items-center justify-center text-sm text-slate-500"><Loader2 className="mr-2 size-4 animate-spin" /> Uitnodiging controleren…</div>;

  return (
    <form onSubmit={(event) => void submit(event)}>
      {error && <div role="alert" className="mt-6 flex gap-2 rounded-xl border border-red-100 bg-red-50 p-3 text-xs text-danger"><AlertTriangle className="size-4 shrink-0" />{error}</div>}
      {sessionReady && <>{factorId && <><label htmlFor="recovery-mfa-code" className="mt-7 block text-xs font-semibold text-ink">Zescijferige verificatiecode</label><div className="relative mt-2"><KeyRound className="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" /><input id="recovery-mfa-code" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" maxLength={6} required value={mfaCode} onChange={(event) => setMfaCode(event.target.value.replace(/\D/g, "").slice(0, 6))} className="h-11 w-full rounded-lg border border-line pl-10 pr-3 text-center font-mono text-base tracking-[0.3em] outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></div><p className="mt-2 text-[11px] leading-5 text-slate-500">Gebruik de bestaande Duindorp SV-code uit je authenticator-app.</p></>}<label htmlFor="new-password" className={`${factorId ? "mt-5" : "mt-7"} block text-xs font-semibold text-ink`}>Nieuw wachtwoord</label>
      <div className="relative mt-2"><KeyRound className="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" /><input id="new-password" type="password" autoComplete="new-password" minLength={16} required value={password} onChange={(event) => setPassword(event.target.value)} className="h-11 w-full rounded-lg border border-line pl-10 pr-3 text-sm outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></div>
      <label htmlFor="confirm-password" className="mt-4 block text-xs font-semibold text-ink">Herhaal wachtwoord</label>
      <div className="relative mt-2"><KeyRound className="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" /><input id="confirm-password" type="password" autoComplete="new-password" minLength={16} required value={confirmation} onChange={(event) => setConfirmation(event.target.value)} className="h-11 w-full rounded-lg border border-line pl-10 pr-3 text-sm outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></div>
      <button disabled={busy} className="mt-5 flex h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 text-sm font-semibold text-white hover:bg-brand-900 disabled:bg-slate-300">{busy ? <Loader2 className="size-4 animate-spin" /> : <ShieldCheck className="size-4" />} Wachtwoord opslaan</button></>}
    </form>
  );
}
