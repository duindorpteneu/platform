import { ArrowRight, FileSpreadsheet } from "lucide-react";
import Link from "next/link";

export function ImportPanel() {
  return (
    <section className="rounded-xl border border-line bg-white p-5 shadow-card">
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="text-base font-bold text-brand-900">Sportlink importeren</h2>
          <p className="mt-1 text-xs leading-5 text-slate-500">
            Kies zelf de velden en productmaatkolommen, controleer een volledige dry-run en verwerk pas daarna.
          </p>
        </div>
        <FileSpreadsheet className="size-5 shrink-0 text-brand-500" />
      </div>
      <Link
        href="/backoffice/leden/importeren"
        className="mt-5 inline-flex h-10 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white transition-colors hover:bg-brand-900"
      >
        Open importwizard <ArrowRight className="size-4" />
      </Link>
    </section>
  );
}
