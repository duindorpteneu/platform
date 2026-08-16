import { Clock3 } from "lucide-react";
import Image from "next/image";
import Link from "next/link";

export default function PaymentReturnPage() {
  return (
    <main className="min-h-screen bg-canvas px-5 py-12">
      <div className="mx-auto flex min-h-[calc(100vh-96px)] max-w-[520px] flex-col justify-center">
        <div className="rounded-2xl border border-line bg-white p-7 text-center shadow-card sm:p-9">
          <div className="mx-auto size-16 rounded-2xl border border-brand-100 bg-white p-1.5">
            <Image src="/duindorp-sv-logo.png" alt="Duindorp SV" width={52} height={52} className="size-full object-contain" priority />
          </div>
          <div className="mx-auto mt-6 flex size-11 items-center justify-center rounded-xl bg-brand-50 text-brand-700">
            <Clock3 className="size-5" aria-hidden="true" />
          </div>
          <p className="mt-5 text-xs font-bold uppercase tracking-[0.14em] text-brand-500">Betaling teruggekoppeld</p>
          <h1 className="mt-2 text-2xl font-bold tracking-tight text-brand-900">Betaling wordt gecontroleerd</h1>
          <p className="mx-auto mt-3 max-w-sm text-sm leading-6 text-slate-500">Mollie verwerkt de betaling op de achtergrond. Je actuele betaalstatus verschijnt in het overzicht zodra de beveiligde bevestiging is ontvangen.</p>
          <Link href="/mijn-tenue" className="mt-7 inline-flex items-center justify-center rounded-lg bg-brand-700 px-4 py-2.5 text-xs font-semibold text-white hover:bg-brand-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2">Naar mijn overzicht</Link>
        </div>
      </div>
    </main>
  );
}
