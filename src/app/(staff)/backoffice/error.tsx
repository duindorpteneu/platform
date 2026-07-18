"use client";

import { AlertTriangle, RefreshCw } from "lucide-react";

export default function BackofficeError({ reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return <div className="mx-auto flex min-h-[60vh] max-w-xl items-center justify-center"><section role="alert" className="w-full rounded-2xl border border-red-100 bg-white p-8 text-center shadow-card"><div className="mx-auto flex size-12 items-center justify-center rounded-xl bg-red-50 text-danger"><AlertTriangle className="size-5" /></div><h1 className="mt-5 text-xl font-bold text-brand-900">Dashboard tijdelijk niet beschikbaar</h1><p className="mt-2 text-sm leading-6 text-slate-500">De operationele gegevens konden niet veilig worden geladen. Er worden geen verouderde voorbeeldcijfers getoond.</p><button onClick={reset} className="mx-auto mt-6 flex h-11 items-center justify-center gap-2 rounded-lg bg-brand-700 px-5 text-sm font-semibold text-white hover:bg-brand-900"><RefreshCw className="size-4" /> Opnieuw proberen</button></section></div>;
}
