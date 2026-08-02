import type { LucideIcon } from "lucide-react";
import { ArrowRight, Banknote, Boxes, ClipboardCheck, History, PackageCheck, QrCode, Upload, UsersRound } from "lucide-react";
import Link from "next/link";
import type { DashboardMetric, DashboardOverview } from "@/lib/dashboard-contract";
import { MetricCard } from "@/components/dashboard/metric-card";
import { StatusBadge } from "@/components/dashboard/status-badge";

const activityPresentation: Record<string, { title: string; description: string; icon: LucideIcon }> = {
  "members.import.commit": { title: "Sportlink-import voltooid", description: "Het ledenbestand is transactioneel bijgewerkt.", icon: UsersRound },
  "stock.receipt.created": { title: "Levering geregistreerd", description: "Ontvangen voorraad is aan het register toegevoegd.", icon: Boxes },
  "stock.lines.reserved": { title: "Voorraad toegewezen", description: "Artikelregels zijn op Af te halen gezet.", icon: ClipboardCheck },
  "payment.manual.recorded": { title: "Handmatige betaling geregistreerd", description: "Een exacte kas- of pinbetaling is bevestigd.", icon: Banknote },
  "qr.created": { title: "QR-code geactiveerd", description: "Een betaalde bestelling heeft een actieve QR-code.", icon: QrCode },
  "fulfilment.completed": { title: "Uitgifte voltooid", description: "Geselecteerde artikelregels zijn atomair uitgegeven.", icon: PackageCheck },
};

function percentage(value: number, total: number) {
  if (total === 0) return "Nog geen bestellingen";
  return `${new Intl.NumberFormat("nl-NL", { maximumFractionDigits: 1 }).format((value / total) * 100)}% van bestellingen`;
}

function initials(name: string) {
  return name.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]?.toUpperCase()).join("") || "DS";
}

function formatMoment(value: string) {
  return new Intl.DateTimeFormat("nl-NL", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit", timeZone: "Europe/Amsterdam" }).format(new Date(value));
}

export function Dashboard({ overview, displayName }: { overview: DashboardOverview; displayName: string }) {
  const firstName = displayName.split(/\s+/).find(Boolean) ?? displayName;
  const metrics: DashboardMetric[] = [
    { label: "Actieve leden", value: overview.metrics.totalMembers.toLocaleString("nl-NL"), detail: "Actief in de huidige ledenimport", tone: "blue" },
    { label: "Betaald", value: overview.metrics.paidOrders.toLocaleString("nl-NL"), detail: percentage(overview.metrics.paidOrders, overview.metrics.totalOrders), tone: "green" },
    { label: "Nog niet betaald", value: overview.metrics.unpaidOrders.toLocaleString("nl-NL"), detail: overview.metrics.unpaidOrders > 0 ? "Opvolging nodig" : "Geen openstaande orders", tone: "amber" },
    { label: "Gedeeltelijk af te halen", value: overview.metrics.partiallyReadyOrders.toLocaleString("nl-NL"), detail: "Gereed én nalevering", tone: "slate" },
    { label: "Volledig af te halen", value: overview.metrics.fullyReadyOrders.toLocaleString("nl-NL"), detail: "Alle regels gereed", tone: "green" },
    { label: "Naleveringen", value: overview.metrics.backorderOrders.toLocaleString("nl-NL"), detail: "Orders met wachtende regels", tone: "amber" },
  ];

  return (
    <div className="mx-auto max-w-[1440px]">
      <div className="flex flex-col justify-between gap-5 sm:flex-row sm:items-end">
        <div>
          <p className="text-xs font-semibold uppercase tracking-[0.12em] text-brand-500">Operationeel dashboard</p>
          <h1 className="mt-2 text-[30px] font-bold tracking-[-0.04em] text-brand-900 md:text-[34px]">Welkom terug, {firstName}</h1>
          <p className="mt-2 text-sm text-slate-500">{overview.activeSeason ? `Actuele stand voor seizoen ${overview.activeSeason.name}.` : "Er is nog geen actief seizoen ingesteld."}</p>
        </div>
        <div className="flex flex-col gap-2 min-[420px]:flex-row">
          <Link href="/backoffice/leden/importeren" className="inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-line bg-white px-3.5 text-xs font-semibold text-ink shadow-sm transition-colors hover:border-brand-500"><Upload className="size-4 text-brand-500" /> Leden importeren</Link>
          <Link href="/backoffice/leveringen" className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-3.5 text-xs font-semibold text-white shadow-sm transition-colors hover:bg-brand-900"><Boxes className="size-4" /> Levering registreren</Link>
        </div>
      </div>

      {!overview.activeSeason && <section className="mt-7 rounded-xl border border-amber-200 bg-amber-50 p-5"><h2 className="text-sm font-bold text-amber-900">Geen actief seizoen</h2><p className="mt-1 text-xs leading-5 text-amber-800">Activeer eerst een seizoen via Instellingen. Tot die tijd blijven seizoensgebonden ordertotalen leeg.</p></section>}

      <section className="mt-8 grid grid-cols-2 gap-3 md:grid-cols-3 xl:grid-cols-6" aria-label="Seizoens-KPI's">
        {metrics.map((metric) => <MetricCard key={metric.label} metric={metric} />)}
      </section>

      <div className="mt-8 grid gap-6 xl:grid-cols-[minmax(0,1fr)_340px]">
        <section className="min-w-0 overflow-hidden rounded-xl border border-line bg-white shadow-card">
          <div className="flex flex-col gap-3 border-b border-line px-5 py-5 sm:flex-row sm:items-center sm:justify-between">
            <div><h2 className="text-base font-bold text-brand-900">Recente ledenstatus</h2><p className="mt-1 text-xs text-slate-500">De vijf laatst gewijzigde bestellingen in het actieve seizoen.</p></div>
            <Link href="/backoffice/leden" className="inline-flex items-center gap-1.5 text-xs font-semibold text-brand-700 hover:text-brand-900">Alle leden bekijken <ArrowRight className="size-3.5" /></Link>
          </div>
          {overview.recentMembers.length === 0 ? <div className="px-5 py-16 text-center"><UsersRound className="mx-auto size-7 text-slate-300" /><p className="mt-3 text-sm font-semibold text-slate-600">Nog geen bestellingen in dit seizoen</p><p className="mx-auto mt-1 max-w-sm text-xs leading-5 text-slate-400">Importeer leden en maak individuele bestellingen aan om hier de operationele voortgang te zien.</p></div> : <div className="overflow-x-auto"><table className="w-full min-w-[720px] text-left"><thead><tr className="border-b border-line bg-slate-50/70 text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400"><th className="px-5 py-3">Lid</th><th className="px-3 py-3">Betaling</th><th className="px-3 py-3">Bestelstatus</th><th className="px-3 py-3">Beschikbaar</th></tr></thead><tbody className="divide-y divide-line">{overview.recentMembers.map((member) => { const progress = member.totalQuantity === 0 ? 0 : Math.min(100, (member.progressQuantity / member.totalQuantity) * 100); return <tr key={member.orderId} className="transition-colors hover:bg-brand-50/40"><td className="px-5 py-3.5"><div className="flex items-center gap-3"><div className="flex size-8 items-center justify-center rounded-full bg-brand-50 text-[10px] font-bold text-brand-700">{initials(member.memberName)}</div><div><p className="text-xs font-semibold text-ink">{member.memberName}</p><p className="mt-0.5 text-[10px] text-slate-400">{member.team} · {member.relationNumber ?? "Geen relatienummer"}</p></div></div></td><td className="px-3 py-3.5"><StatusBadge label={member.paymentStatus} /></td><td className="px-3 py-3.5"><StatusBadge label={member.orderStatus} /></td><td className="px-3 py-3.5"><div className="flex items-center gap-2"><div className="h-1.5 w-16 overflow-hidden rounded-full bg-slate-100"><div className="h-full rounded-full bg-brand-500" style={{ width: `${progress}%` }} /></div><span className="text-[11px] text-slate-500">{member.progressQuantity} van {member.totalQuantity}</span></div></td></tr>; })}</tbody></table></div>}
          <div className="flex items-center justify-between border-t border-line px-5 py-3.5"><p className="text-[11px] text-slate-400">{overview.recentMembers.length} recente {overview.recentMembers.length === 1 ? "bestelling" : "bestellingen"}</p><Link href="/backoffice/leden" className="text-xs font-semibold text-brand-700 hover:text-brand-900">Bekijk alle leden</Link></div>
        </section>

        <aside className="space-y-6">
          <section className="rounded-xl border border-line bg-white shadow-card"><div className="border-b border-line px-5 py-5"><h2 className="text-base font-bold text-brand-900">Activiteit</h2><p className="mt-1 text-xs text-slate-500">Recente geauditeerde gebeurtenissen</p></div>{overview.activities.length === 0 ? <div className="px-5 py-12 text-center"><History className="mx-auto size-6 text-slate-300" /><p className="mt-3 text-xs text-slate-500">Nog geen operationele activiteit</p></div> : <div className="divide-y divide-line px-5">{overview.activities.map((item) => { const presentation = activityPresentation[item.action] ?? { title: "Operationele wijziging", description: `Gebeurtenis voor ${item.entityType}.`, icon: History }; const Icon = presentation.icon; return <div key={item.id} className="flex gap-3 py-4"><div className="flex size-8 shrink-0 items-center justify-center rounded-lg bg-brand-50 text-brand-700"><Icon className="size-4" strokeWidth={1.8} /></div><div className="min-w-0"><p className="text-xs font-semibold text-ink">{presentation.title}</p><p className="mt-1 text-[11px] leading-4 text-slate-500">{presentation.description}</p><p className="mt-1.5 text-[10px] text-slate-400">{formatMoment(item.createdAt)}</p></div></div>; })}</div>}</section>
          <section className="overflow-hidden rounded-xl bg-brand-900 p-5 text-white shadow-card"><div className="flex items-center justify-between"><div className="flex size-9 items-center justify-center rounded-lg bg-white/10"><PackageCheck className="size-[18px] text-blue-100" /></div><span className="rounded-full bg-emerald-400/15 px-2 py-1 text-[10px] font-semibold text-emerald-300">Live status</span></div><h2 className="mt-5 text-base font-bold">Gereed voor uitgifte</h2><p className="mt-1 text-xs leading-5 text-blue-100/75">Orders met minimaal één artikelregel die fysiek af te halen is.</p><div className="mt-5 flex items-end justify-between"><div><p className="text-3xl font-bold tracking-[-0.04em]">{overview.metrics.readyOrders.toLocaleString("nl-NL")}</p><p className="mt-1 text-[11px] text-blue-100/70">orders gereed</p></div><Link href="/uitgifte" className="flex size-9 items-center justify-center rounded-lg bg-white text-brand-900 transition-colors hover:bg-blue-50" aria-label="Open uitgifte"><ArrowRight className="size-4" /></Link></div></section>
        </aside>
      </div>
    </div>
  );
}
