"use client";

import { AlertTriangle, RefreshCw } from "lucide-react";

export default function PackagesError({ reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <div className="mx-auto max-w-2xl rounded-xl border border-red-100 bg-white p-8 text-center shadow-card">
      <AlertTriangle className="mx-auto size-9 text-danger" />
      <h1 className="mt-4 text-xl font-bold text-brand-900">Pakketbeheer kon niet worden geladen</h1>
      <p className="mt-2 text-sm text-slate-500">Controleer je beheerderssessie en probeer de actuele gegevens opnieuw te laden.</p>
      <button type="button" onClick={reset} className="mt-6 inline-flex h-10 items-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900">
        <RefreshCw className="size-4" /> Opnieuw proberen
      </button>
    </div>
  );
}
