"use client";

import { ArrowRight, Loader2 } from "lucide-react";
import { useRouter } from "next/navigation";
import { useState } from "react";

export function ParentCodeForm() {
  const router = useRouter();
  const [code, setCode] = useState(""); const [error, setError] = useState<string | null>(null); const [loading, setLoading] = useState(false);
  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault(); setError(null); setLoading(true);
    try { const response = await fetch("/api/parent-auth/verify-code", { method: "POST", headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" }, body: JSON.stringify({ code }) }); const payload = await response.json() as { error?: string }; if (!response.ok) throw new Error(payload.error ?? "De code is ongeldig of verlopen."); router.push("/mijn-tenue"); } catch (cause) { setError(cause instanceof Error ? cause.message : "De code kon niet worden gecontroleerd."); } finally { setLoading(false); }
  }
  return <form onSubmit={submit} className="rounded-2xl border border-line bg-white p-6 text-left shadow-card"><p className="text-xs leading-5 text-slate-500">Vul de code in die naar het opgegeven e-mailadres is gestuurd.</p><label htmlFor="parent-code" className="mt-6 block text-xs font-semibold text-ink">Zescijferige verificatiecode</label><input id="parent-code" inputMode="numeric" autoComplete="one-time-code" pattern="[0-9]{6}" maxLength={6} required value={code} onChange={(event) => setCode(event.target.value.replace(/\D/g, "").slice(0, 6))} className="mt-2 h-14 w-full rounded-lg border border-line text-center text-2xl font-bold tracking-[0.45em] text-brand-900 outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" />{error && <p className="mt-3 text-xs text-danger">{error}</p>}<button disabled={loading || code.length !== 6} className="mt-5 flex h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 text-sm font-semibold text-white hover:bg-brand-900 disabled:bg-slate-200 disabled:text-slate-400">{loading && <Loader2 className="size-4 animate-spin" />}{loading ? "Controleren…" : "Ga naar mijn tenue"}<ArrowRight className="size-4" /></button><p className="mt-4 text-center text-[11px] leading-5 text-slate-400">De code is tien minuten geldig en eenmalig te gebruiken.</p></form>;
}
