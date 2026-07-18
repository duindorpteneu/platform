"use client";

import { AlertTriangle, RefreshCw } from "lucide-react";

export default function SettingsError({ reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return <div className="mx-auto max-w-2xl rounded-xl border border-red-100 bg-white p-8 text-center shadow-card"><span className="mx-auto flex size-12 items-center justify-center rounded-xl bg-red-50 text-danger"><AlertTriangle className="size-6" /></span><h1 className="mt-5 text-xl font-bold text-brand-900">Instellingen niet beschikbaar</h1><p className="mt-2 text-sm leading-6 text-slate-500">De beveiligde instellingenworkspace kon niet worden geladen. Controleer uw beheerdersrol en MFA-sessie.</p><button type="button" onClick={reset} className="mt-6 inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-bold text-white hover:bg-brand-900"><RefreshCw className="size-4" />Opnieuw proberen</button></div>;
}
