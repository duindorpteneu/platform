"use client";

import { AlertTriangle, RefreshCw } from "lucide-react";

export default function PaymentsError({ reset }: { error: Error; reset: () => void }) {
  return <div className="mx-auto max-w-2xl rounded-xl border border-red-100 bg-white p-8 text-center shadow-card"><AlertTriangle className="mx-auto size-9 text-danger" aria-hidden="true" /><h1 className="mt-4 text-xl font-bold text-brand-900">Betalingen konden niet worden geladen</h1><p className="mt-2 text-sm leading-6 text-slate-500">De administratie blijft veilig gesloten. Probeer de actuele betaalstatus opnieuw op te halen.</p><button type="button" onClick={reset} className="mt-6 inline-flex h-10 items-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-bold text-white hover:bg-brand-900"><RefreshCw className="size-4" aria-hidden="true" /> Opnieuw proberen</button></div>;
}
