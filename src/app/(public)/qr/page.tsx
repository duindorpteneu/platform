import { ShieldCheck } from "lucide-react";
import Image from "next/image";
import { QrFragmentScrubber } from "@/components/fulfilment/qr-fragment-scrubber";

export default function QrLandingPage() {
  return (
    <main className="flex min-h-screen items-center justify-center bg-canvas px-5 py-10">
      <QrFragmentScrubber />
      <section className="w-full max-w-[520px] rounded-2xl border border-line bg-white p-8 text-center shadow-card md:p-12">
        <div className="mx-auto flex size-16 items-center justify-center rounded-2xl border border-line bg-white p-2 shadow-sm">
          <Image src="/duindorp-sv-logo.png" alt="Duindorp SV" width={52} height={52} className="size-full object-contain" priority />
        </div>
        <p className="mt-6 text-xs font-bold uppercase tracking-[0.14em] text-brand-500">Duindorp SV Tenueportaal</p>
        <h1 className="mt-2 text-2xl font-bold tracking-tight text-brand-900">QR-code voor tenue-uitgifte</h1>
        <p className="mx-auto mt-3 max-w-sm text-sm leading-6 text-slate-500">Laat deze code bij de uitgiftebalie scannen door een ingelogde medewerker. Op deze openbare pagina worden geen lidgegevens getoond.</p>
        <div className="mt-7 inline-flex items-center gap-2 rounded-lg bg-emerald-50 px-3 py-2 text-xs font-semibold text-success"><ShieldCheck className="size-4" /> Beveiligde controle bij de balie</div>
      </section>
    </main>
  );
}
