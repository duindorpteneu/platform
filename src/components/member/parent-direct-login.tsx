"use client";

import { Loader2 } from "lucide-react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";

export function ParentDirectLogin() {
  const router = useRouter();
  const started = useRef(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (started.current) return;
    started.current = true;
    const credential = window.location.hash.slice(1);
    window.history.replaceState(null, "", "/login/direct");
    if (!credential) {
      setError("Deze inloglink klopt niet of is niet meer geldig.");
      return;
    }
    void (async () => {
      try {
        const response = await fetch("/api/parent-auth/verify-direct", {
          method: "POST",
          cache: "no-store",
          credentials: "same-origin",
          headers: {
            "Content-Type": "application/json",
            "X-Duindorp-CSRF": "same-origin",
          },
          body: JSON.stringify({ credential }),
        });
        const payload = await response.json() as { error?: string };
        if (!response.ok) {
          throw new Error(
            payload.error ?? "Deze inloglink klopt niet of is niet meer geldig.",
          );
        }
        router.replace("/mijn-tenue");
      } catch (cause) {
        setError(cause instanceof Error
          ? cause.message
          : "Inloggen is tijdelijk niet beschikbaar.");
      }
    })();
  }, [router]);

  if (error) {
    return (
      <div className="rounded-2xl border border-line bg-white p-6 text-center shadow-card">
        <p className="text-sm leading-6 text-danger">{error}</p>
        <Link
          className="mt-5 inline-flex h-11 items-center justify-center rounded-lg bg-brand-700 px-5 text-sm font-semibold text-white hover:bg-brand-900"
          href="/login"
        >
          Nieuwe code aanvragen
        </Link>
      </div>
    );
  }

  return (
    <div
      aria-live="polite"
      className="rounded-2xl border border-line bg-white p-6 text-center shadow-card"
    >
      <Loader2 aria-hidden="true" className="mx-auto size-6 animate-spin text-brand-700" />
      <p className="mt-4 text-sm font-semibold text-brand-900">
        Veilige inloglink controleren…
      </p>
      <p className="mt-2 text-xs leading-5 text-slate-500">
        Je wordt automatisch doorgestuurd naar jouw tenue.
      </p>
    </div>
  );
}
