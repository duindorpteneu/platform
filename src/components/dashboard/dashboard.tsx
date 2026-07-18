import { ArrowRight, ChevronRight, Filter, MoreHorizontal, PackageCheck, Plus, Search, Upload, UsersRound } from "lucide-react";
import { activityItems, dashboardMetrics, memberRows } from "@/lib/dashboard-data";
import { MetricCard } from "@/components/dashboard/metric-card";
import { StatusBadge } from "@/components/dashboard/status-badge";

const activityIcons = { package: PackageCheck, mail: Upload, users: UsersRound, rotate: MoreHorizontal } as const;

export function Dashboard() {
  return (
    <div className="mx-auto max-w-[1440px]">
      <div className="flex flex-col justify-between gap-5 sm:flex-row sm:items-end">
        <div>
          <p className="text-xs font-semibold uppercase tracking-[0.12em] text-brand-500">Dinsdag 18 juli 2026</p>
          <h1 className="mt-2 text-[30px] font-bold tracking-[-0.04em] text-brand-900 md:text-[34px]">Goedemorgen, Danny</h1>
          <p className="mt-2 text-sm text-slate-500">Hier is de actuele stand van het tenueproces voor seizoen 2025/26.</p>
        </div>
        <div className="flex gap-2">
          <button className="inline-flex items-center justify-center gap-2 rounded-lg border border-line bg-white px-3.5 py-2.5 text-xs font-semibold text-ink shadow-sm transition-colors hover:border-brand-500"><Upload className="size-4 text-brand-500" /> Importeren</button>
          <button className="inline-flex items-center justify-center gap-2 rounded-lg bg-brand-700 px-3.5 py-2.5 text-xs font-semibold text-white shadow-sm transition-colors hover:bg-brand-900"><Plus className="size-4" /> Nieuwe levering</button>
        </div>
      </div>

      <section className="mt-8 grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6" aria-label="Seizoens-KPI's">
        {dashboardMetrics.map((metric) => <MetricCard key={metric.label} metric={metric} />)}
      </section>

      <div className="mt-8 grid gap-6 xl:grid-cols-[minmax(0,1fr)_340px]">
        <section className="min-w-0 rounded-xl border border-line bg-white shadow-card">
          <div className="flex flex-col gap-4 border-b border-line px-5 py-5 sm:flex-row sm:items-center sm:justify-between">
            <div><h2 className="text-base font-bold text-brand-900">Recente ledenstatus</h2><p className="mt-1 text-xs text-slate-500">De laatste wijzigingen in bestellingen en betalingen.</p></div>
            <button className="inline-flex items-center gap-1.5 text-xs font-semibold text-brand-700 hover:text-brand-900">Alle leden bekijken <ArrowRight className="size-3.5" /></button>
          </div>
          <div className="flex flex-col gap-3 border-b border-line px-5 py-4 sm:flex-row">
            <div className="relative flex-1"><Search className="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" /><input className="h-9 w-full rounded-lg border border-line bg-canvas pl-9 pr-3 text-xs outline-none transition-colors placeholder:text-slate-400 focus:border-brand-500 focus:bg-white focus:ring-2 focus:ring-brand-100" placeholder="Zoek op naam, team of relatienummer" /></div>
            <button className="inline-flex h-9 items-center justify-center gap-2 rounded-lg border border-line px-3 text-xs font-semibold text-slate-600 hover:border-brand-500 hover:text-brand-700"><Filter className="size-3.5" /> Filters <span className="rounded bg-brand-50 px-1.5 py-0.5 text-[10px] text-brand-700">2</span></button>
          </div>
          <div className="overflow-x-auto">
            <table className="w-full min-w-[720px] text-left">
              <thead><tr className="border-b border-line bg-slate-50/70 text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400"><th className="px-5 py-3">Lid</th><th className="px-3 py-3">Betaling</th><th className="px-3 py-3">Bestelstatus</th><th className="px-3 py-3">Voortgang</th><th className="px-3 py-3" /></tr></thead>
              <tbody className="divide-y divide-line">
                {memberRows.map((member) => <tr key={member.relationNumber} className="group transition-colors hover:bg-brand-50/40">
                  <td className="px-5 py-3.5"><div className="flex items-center gap-3"><div className="flex size-8 items-center justify-center rounded-full bg-brand-50 text-[10px] font-bold text-brand-700">{member.initials}</div><div><p className="text-xs font-semibold text-ink">{member.name}</p><p className="mt-0.5 text-[10px] text-slate-400">{member.team} · {member.relationNumber}</p></div></div></td>
                  <td className="px-3 py-3.5"><StatusBadge label={member.payment} /></td>
                  <td className="px-3 py-3.5"><StatusBadge label={member.order} /></td>
                  <td className="px-3 py-3.5"><div className="flex items-center gap-2"><div className="h-1.5 w-16 overflow-hidden rounded-full bg-slate-100"><div className="h-full rounded-full bg-brand-500" style={{ width: `${member.progress === "0 van 3" ? 0 : member.progress === "1 van 4" ? 25 : member.progress === "2 van 4" ? 50 : 100}%` }} /></div><span className="text-[11px] text-slate-500">{member.progress}</span></div></td>
                  <td className="px-3 py-3.5 text-right"><button aria-label={`Open ${member.name}`} className="rounded-md p-1.5 text-slate-300 opacity-0 transition-all hover:bg-white hover:text-brand-700 group-hover:opacity-100"><ChevronRight className="size-4" /></button></td>
                </tr>)}
              </tbody>
            </table>
          </div>
          <div className="flex items-center justify-between border-t border-line px-5 py-3.5"><p className="text-[11px] text-slate-400">Toont 5 van 486 leden</p><button className="text-xs font-semibold text-brand-700 hover:text-brand-900">Bekijk alle leden</button></div>
        </section>

        <aside className="space-y-6">
          <section className="rounded-xl border border-line bg-white shadow-card"><div className="flex items-center justify-between border-b border-line px-5 py-5"><div><h2 className="text-base font-bold text-brand-900">Activiteit</h2><p className="mt-1 text-xs text-slate-500">Recente gebeurtenissen</p></div><button className="rounded-md p-1.5 text-slate-400 hover:bg-canvas hover:text-brand-700"><MoreHorizontal className="size-4" /></button></div><div className="divide-y divide-line px-5">{activityItems.map((item) => { const Icon = activityIcons[item.icon as keyof typeof activityIcons]; return <div key={item.title} className="flex gap-3 py-4"><div className="flex size-8 shrink-0 items-center justify-center rounded-lg bg-brand-50 text-brand-700"><Icon className="size-4" strokeWidth={1.8} /></div><div className="min-w-0"><p className="text-xs font-semibold text-ink">{item.title}</p><p className="mt-1 text-[11px] leading-4 text-slate-500">{item.description}</p><p className="mt-1.5 text-[10px] text-slate-400">{item.time}</p></div></div>; })}</div><button className="flex w-full items-center justify-center gap-1 border-t border-line py-3.5 text-xs font-semibold text-brand-700 hover:text-brand-900">Alle activiteit <ArrowRight className="size-3.5" /></button></section>
          <section className="overflow-hidden rounded-xl bg-brand-900 p-5 text-white shadow-card"><div className="flex items-center justify-between"><div className="flex size-9 items-center justify-center rounded-lg bg-white/10"><PackageCheck className="size-[18px] text-blue-100" /></div><span className="rounded-full bg-emerald-400/15 px-2 py-1 text-[10px] font-semibold text-emerald-300">Op schema</span></div><h2 className="mt-5 text-base font-bold">Volgende uitgifte</h2><p className="mt-1 text-xs leading-5 text-blue-100/75">Zaterdag 22 juli · Sportpark Houtrust</p><div className="mt-5 flex items-end justify-between"><div><p className="text-3xl font-bold tracking-[-0.04em]">126</p><p className="mt-1 text-[11px] text-blue-100/70">orders gereed</p></div><button className="flex size-9 items-center justify-center rounded-lg bg-white text-brand-900 transition-colors hover:bg-blue-50" aria-label="Open uitgifte"><ArrowRight className="size-4" /></button></div></section>
        </aside>
      </div>
    </div>
  );
}
