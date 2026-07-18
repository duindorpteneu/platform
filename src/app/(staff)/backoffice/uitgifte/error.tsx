"use client";
export default function FulfilmentHistoryError({ reset }: { error: Error; reset: () => void }) {
  return <div className="mx-auto max-w-xl rounded-xl border border-red-100 bg-white p-8 text-center shadow-card"><h1 className="text-lg font-bold text-brand-900">Uitgiftehistorie niet beschikbaar</h1><p className="mt-2 text-sm leading-6 text-slate-500">De beveiligde gegevens konden niet worden geladen. Er zijn geen correcties uitgevoerd.</p><button onClick={reset} className="mt-5 h-10 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900">Opnieuw proberen</button></div>;
}

