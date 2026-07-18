import { CheckCircle2, CircleAlert, Clock3, Users } from "lucide-react";
import type { DashboardMetric } from "@/lib/dashboard-contract";
import { cn } from "@/lib/utils";

const toneMap = {
  blue: { icon: Users, iconClass: "bg-brand-50 text-brand-700", valueClass: "text-brand-900" },
  green: { icon: CheckCircle2, iconClass: "bg-emerald-50 text-success", valueClass: "text-ink" },
  amber: { icon: CircleAlert, iconClass: "bg-amber-50 text-warning", valueClass: "text-ink" },
  slate: { icon: Clock3, iconClass: "bg-slate-100 text-slate-600", valueClass: "text-ink" },
};

export function MetricCard({ metric }: { metric: DashboardMetric }) {
  const tone = toneMap[metric.tone];
  const Icon = tone.icon;
  return (
    <article className="rounded-xl border border-line bg-white p-5 text-left shadow-card">
      <div className="flex items-start justify-between">
        <div className={cn("flex size-9 items-center justify-center rounded-lg", tone.iconClass)}><Icon className="size-[18px]" strokeWidth={1.8} /></div>
      </div>
      <p className="mt-5 text-xs font-medium text-slate-500">{metric.label}</p>
      <p className={cn("mt-1 text-[27px] font-bold tracking-[-0.04em]", tone.valueClass)}>{metric.value}</p>
      <p className="mt-1 text-[11px] text-slate-400">{metric.detail}</p>
    </article>
  );
}
