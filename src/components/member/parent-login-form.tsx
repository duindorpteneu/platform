"use client";

import { ArrowRight, Loader2, Mail } from "lucide-react";
import { useRouter } from "next/navigation";
import { useState } from "react";

export function ParentLoginForm() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault(); setError(null); setLoading(true);
    try {
      const response = await fetch("/api/parent-auth/request-code", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ email }) });
      const payload = await response.json() as { error?: string };
      if (!response.ok) throw new Error(payload.error ?? "Voer een geldig e-mailadres in.");
      router.push(`/login/code?email=${encodeURIComponent(email.trim().toLowerCase())}`);
    } catch (cause) { setError(cause instanceof Error ? cause.message : "De aanvraag kon niet worden verstuurd."); } finally { setLoading(false); }
  }

  return <form onSubmit={submit} className="rounded-2xl border border-line bg-white p-6 text-left shadow-card"><label htmlFor="parent-email" className="text-xs font-semibold text-ink">E-mailadres</label><div className="relative mt-2"><Mail className="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" /><input id="parent-email" type="email" required autoComplete="email" value={email} onChange={(event) => setEmail(event.target.value)} placeholder="naam@voorbeeld.nl" className="h-11 w-full rounded-lg border border-line pl-10 pr-3 text-sm outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></div>{error && <p className="mt-3 text-xs text-danger">{error}</p>}<button disabled={loading} className="mt-4 flex h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 text-sm font-semibold text-white hover:bg-brand-900 disabled:bg-slate-200 disabled:text-slate-400">{loading && <Loader2 className="size-4 animate-spin" />}{loading ? "Code aanvragen…" : "Verstuur verificatiecode"} <ArrowRight className="size-4" /></button><p className="mt-4 text-center text-[11px] leading-5 text-slate-400">Als dit e-mailadres bij ons bekend is, is een code verzonden.</p></form>;
}
