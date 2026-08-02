"use client";

import Link from "next/link";

export default function DynamicImportError() {
  return (
    <div className="mx-auto max-w-xl rounded-xl border border-red-100 bg-red-50 p-6">
      <h1 className="text-lg font-bold text-red-950">Importwizard tijdelijk niet beschikbaar</h1>
      <p className="mt-2 text-sm text-red-800">Er zijn geen leden of uploads gewijzigd. Probeer de beveiligde werkruimte opnieuw.</p>
      <Link href="/backoffice/leden" className="mt-5 inline-flex h-10 items-center rounded-lg bg-white px-4 text-xs font-semibold text-brand-700">Terug naar leden</Link>
    </div>
  );
}
