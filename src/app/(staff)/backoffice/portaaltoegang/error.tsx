"use client";

import { AlertTriangle } from "lucide-react";

export default function PortalAccessError({ reset }: { error: Error; reset: () => void }) {
  return (
    <div className="mx-auto max-w-xl rounded-xl border border-red-200 bg-white p-8 text-center shadow-card">
      <AlertTriangle className="mx-auto size-8 text-danger" />
      <h1 className="mt-4 text-xl font-bold text-brand-900">Portaaltoegang tijdelijk niet beschikbaar</h1>
      <p className="mt-2 text-sm text-slate-500">De beveiligde leden- en grantgegevens konden niet worden geladen.</p>
      <button type="button" onClick={reset} className="mt-6 rounded-lg bg-brand-700 px-4 py-2.5 text-xs font-semibold text-white">Opnieuw proberen</button>
    </div>
  );
}
