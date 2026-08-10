"use client";

import { KeyRound, Loader2 } from "lucide-react";
import { type FormEvent, useState } from "react";
import { useRouter } from "next/navigation";

export function SupplierLoginForm() {
  const router = useRouter();
  const [accessToken, setAccessToken] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError(null);
    try {
      const response = await fetch("/api/supplier-auth/session", {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          "X-Duindorp-CSRF": "same-origin",
        },
        body: JSON.stringify({ accessToken }),
      });
      if (!response.ok) {
        setError(response.status === 503
          ? "Inloggen is tijdelijk niet beschikbaar. Probeer het later opnieuw."
          : "De toegangssleutel is ongeldig, ingetrokken of verlopen.");
        return;
      }
      router.replace("/leverancier");
      router.refresh();
    } catch {
      setError("Inloggen is tijdelijk niet beschikbaar.");
    } finally {
      setBusy(false);
    }
  }

  return <form onSubmit={submit} className="mt-7 space-y-5">
    {error && <p role="alert" className="rounded-lg border border-red-100 bg-red-50 p-3 text-xs leading-5 text-danger">{error}</p>}
    <label className="block text-xs font-semibold text-ink">
      Toegangssleutel
      <input
        className="mt-2 h-12 w-full rounded-lg border border-line bg-white px-3 font-mono text-sm outline-none transition focus:border-brand-500 focus:ring-2 focus:ring-brand-100"
        type="password"
        value={accessToken}
        onChange={(event) => setAccessToken(event.target.value)}
        autoComplete="off"
        spellCheck={false}
        maxLength={80}
        required
      />
    </label>
    <button type="submit" disabled={busy || !accessToken.trim()} className="inline-flex h-12 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 px-5 text-sm font-bold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:opacity-50">
      {busy ? <Loader2 className="size-4 animate-spin" /> : <KeyRound className="size-4" />}
      Planning openen
    </button>
  </form>;
}
