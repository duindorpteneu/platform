import { cn } from "@/lib/utils";

const statusStyles = {
  Betaald: "bg-emerald-50 text-success ring-emerald-100",
  "Nog te betalen": "bg-amber-50 text-warning ring-amber-100",
  "Controle vereist": "bg-rose-50 text-danger ring-rose-100",
  "Volledig af te halen": "bg-blue-50 text-brand-700 ring-blue-100",
  "Gedeeltelijk af te halen": "bg-violet-50 text-violet-700 ring-violet-100",
  Nalevering: "bg-amber-50 text-warning ring-amber-100",
  "Nog niet betaald": "bg-slate-100 text-slate-600 ring-slate-200",
  "Gedeeltelijk afgehaald": "bg-violet-50 text-violet-700 ring-violet-100",
  Afgerond: "bg-emerald-50 text-success ring-emerald-100",
};

export function StatusBadge({ label }: { label: keyof typeof statusStyles }) {
  return <span className={cn("inline-flex items-center gap-1.5 rounded-md px-2 py-1 text-[11px] font-semibold ring-1 ring-inset", statusStyles[label])}><span className="size-1.5 rounded-full bg-current" />{label}</span>;
}
