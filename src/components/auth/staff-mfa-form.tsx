"use client";

import Image from "next/image";
import { AlertTriangle, CheckCircle2, KeyRound, Loader2, LogOut, ShieldCheck } from "lucide-react";
import { FormEvent, useEffect, useRef, useState } from "react";
import { getSupabaseBrowserClient } from "@/lib/supabase/client";
import { resolveStaffLandingPathWithRetry, synchronizeStaffSession } from "@/lib/staff-session";
import { z } from "zod";

type Enrollment = { factorId: string; qrCode: string; secret: string };
const exchangeSchema = z.object({ exchangeToken: z.string().regex(/^[0-9a-f]{64}$/) }).strict();

export function StaffMfaForm() {
  const started = useRef(false);
  const [factorId, setFactorId] = useState<string | null>(null);
  const [enrollment, setEnrollment] = useState<Enrollment | null>(null);
  const [code, setCode] = useState("");
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (started.current) return;
    started.current = true;
    let active = true;

    async function prepare() {
      const supabase = getSupabaseBrowserClient();
      if (!supabase) {
        if (active) { setError("Medewerkers-MFA is lokaal nog niet geconfigureerd."); setLoading(false); }
        return;
      }

      const { data: userData } = await supabase.auth.getUser();
      if (!userData.user) { window.location.assign("/staff/login"); return; }

      const { data: assurance } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
      if (assurance?.currentLevel === "aal2") {
        const landingPath = await resolveStaffLandingPathWithRetry();
        if (landingPath) {
          window.location.assign(landingPath);
          return;
        }
        await supabase.auth.signOut({ scope: "local" });
        window.location.assign("/staff/login");
        return;
      }

      const { data: factors, error: factorsError } = await supabase.auth.mfa.listFactors();
      if (factorsError || !factors) {
        if (active) { setError("De MFA-status kon niet worden opgehaald."); setLoading(false); }
        return;
      }

      const verified = factors.totp[0];
      if (verified) {
        if (active) { setFactorId(verified.id); setLoading(false); }
        return;
      }

      for (const staleFactor of factors.all.filter((factor) => factor.factor_type === "totp" && factor.status === "unverified")) {
        await supabase.auth.mfa.unenroll({ factorId: staleFactor.id });
      }

      const { data: enrolled, error: enrollError } = await supabase.auth.mfa.enroll({ factorType: "totp", friendlyName: "Duindorp SV Tenueportaal", issuer: "Duindorp SV" });
      if (enrollError || !enrolled) {
        if (active) { setError("De authenticator kon niet worden ingesteld."); setLoading(false); }
        return;
      }
      const qrCode = enrolled.totp.qr_code.startsWith("data:") ? enrolled.totp.qr_code : `data:image/svg+xml;utf-8,${encodeURIComponent(enrolled.totp.qr_code)}`;
      if (active) {
        setFactorId(enrolled.id);
        setEnrollment({ factorId: enrolled.id, qrCode, secret: enrolled.totp.secret });
        setLoading(false);
      }
    }

    void prepare();
    return () => { active = false; };
  }, []);

  async function verify(event: FormEvent) {
    event.preventDefault();
    if (!factorId || !/^\d{6}$/.test(code)) { setError("Voer de zescijferige code uit je authenticator-app in."); return; }
    setBusy(true);
    setError(null);
    const supabase = getSupabaseBrowserClient();
    if (!supabase) {
      setError("Medewerkers-MFA is lokaal nog niet geconfigureerd.");
      setBusy(false);
      return;
    }
    const result = await supabase.auth.mfa.challengeAndVerify({ factorId, code });
    if (result.error) {
      setError("De verificatiecode is niet geldig of verlopen.");
      setBusy(false);
      return;
    }
    const appClient = supabase as unknown as {
      schema(name: "app"): { rpc(name: "create_staff_session_exchange"): Promise<{ data: unknown; error: unknown }> };
    };
    const exchangeResult = await appClient.schema("app").rpc("create_staff_session_exchange");
    const exchange = exchangeSchema.safeParse(exchangeResult.data);
    if (exchangeResult.error || !exchange.success) {
      setError("De beveiligde sessie kon niet met de server worden voorbereid. Probeer het opnieuw.");
      setBusy(false);
      return;
    }
    const landingPath = await synchronizeStaffSession(exchange.data.exchangeToken);
    if (!landingPath) {
      setError("De beveiligde sessie kon niet met de server worden gesynchroniseerd. Probeer het opnieuw.");
      setBusy(false);
      return;
    }
    window.location.assign(landingPath);
  }

  async function cancel() {
    const supabase = getSupabaseBrowserClient();
    await supabase?.auth.signOut({ scope: "local" });
    window.location.assign("/staff/login");
  }

  if (loading) return <div className="flex min-h-48 items-center justify-center text-sm text-slate-500"><Loader2 className="mr-2 size-4 animate-spin" /> MFA-status controleren…</div>;

  return (
    <div>
      {enrollment && <div className="mt-6 rounded-xl border border-line bg-slate-50 p-5"><div className="flex gap-3"><CheckCircle2 className="mt-0.5 size-5 shrink-0 text-success" /><div><h2 className="text-sm font-bold text-brand-900">Authenticator koppelen</h2><p className="mt-1 text-xs leading-5 text-slate-500">Scan deze eenmalige QR-code met je authenticator-app. Deel de QR-code of sleutel nooit.</p></div></div><Image src={enrollment.qrCode} alt="Eenmalige QR-code voor MFA-instelling" width={196} height={196} unoptimized className="mx-auto my-5 rounded-lg bg-white p-2" /><p className="text-[10px] font-semibold uppercase tracking-wider text-slate-400">Handmatige sleutel</p><p className="mt-2 break-all rounded-lg bg-white p-3 font-mono text-xs text-ink">{enrollment.secret}</p></div>}
      {!enrollment && !error && <div className="mt-6 flex gap-3 rounded-xl border border-brand-100 bg-brand-50 p-4 text-brand-900"><ShieldCheck className="size-5 shrink-0" /><div><p className="text-sm font-bold">Tweede stap vereist</p><p className="mt-1 text-xs leading-5 text-brand-700">Open je authenticator-app en voer de actuele code in.</p></div></div>}
      {error && <div role="alert" className="mt-5 flex gap-2 rounded-xl border border-red-100 bg-red-50 p-3 text-xs text-danger"><AlertTriangle className="size-4 shrink-0" />{error}</div>}
      {factorId && <form onSubmit={(event) => void verify(event)}><label htmlFor="mfa-code" className="mt-6 block text-xs font-semibold text-ink">Zescijferige verificatiecode</label><div className="relative mt-2"><KeyRound className="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" /><input id="mfa-code" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" maxLength={6} required value={code} onChange={(event) => setCode(event.target.value.replace(/\D/g, "").slice(0, 6))} className="h-12 w-full rounded-lg border border-line pl-10 pr-3 text-center font-mono text-lg tracking-[0.35em] outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></div><button disabled={busy} className="mt-4 flex h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 text-sm font-semibold text-white hover:bg-brand-900 disabled:bg-slate-300">{busy ? <Loader2 className="size-4 animate-spin" /> : <ShieldCheck className="size-4" />} Beveiligde sessie starten</button></form>}
      <button type="button" onClick={() => void cancel()} className="mt-4 flex h-10 w-full items-center justify-center gap-2 text-xs font-semibold text-slate-500 hover:text-brand-900"><LogOut className="size-3.5" /> Annuleren en uitloggen</button>
    </div>
  );
}
