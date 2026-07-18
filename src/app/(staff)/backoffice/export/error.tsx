"use client";

import { AlertTriangle, RotateCcw } from "lucide-react";

export default function ExportError({ reset }: { reset: () => void }) {
  return <div className="mx-auto max-w-[760px] rounded-xl border border-red-100 bg-white p-8 text-center shadow-card"><div className="mx-auto flex size-11 items-center justify-center rounded-xl bg-red-50 text-danger"><AlertTriangle className="size-5" aria-hidden="true" /></div><h1 className="mt-5 text-xl font-bold text-brand-900">Exports tijdelijk niet beschikbaar</h1><p className="mx-auto mt-2 max-w-lg text-sm leading-6 text-slate-500">De exportselectie kon niet volledig en veilig worden geladen. Er is geen gedeeltelijke dataset vrijgegeven.</p><button type="button" onClick={reset} className="mx-auto mt-6 inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900"><RotateCcw className="size-4" aria-hidden="true" /> Opnieuw proberen</button></div>;
}
