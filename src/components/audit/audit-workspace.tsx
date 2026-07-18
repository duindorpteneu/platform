import { Activity, ChevronRight, Clock3, Filter, KeyRound, Search, ShieldCheck, UserRound } from "lucide-react";
import Link from "next/link";
import type { AuditFilters, AuditWorkspace as Workspace } from "@/lib/settings-audit-contract";

const categoryLabels: Record<Workspace["categories"][number], string> = {
  members: "Leden en imports",
  orders: "Bestellingen",
  payments: "Betalingen",
  inventory: "Voorraad en leveringen",
  fulfilment: "QR en uitgifte",
  communications: "E-mail en exports",
  settings: "Instellingen en staff",
  security: "Authenticatie en security",
};
const formatter = new Intl.DateTimeFormat("nl-NL", { dateStyle: "medium", timeStyle: "short" });

function queryString(filters: AuditFilters, overrides: Partial<Record<keyof AuditFilters, string | undefined>>) {
  const params = new URLSearchParams();
  const merged = { ...filters, ...overrides };
  if (merged.category) params.set("category", merged.category);
  if (merged.action) params.set("action", merged.action);
  if (merged.actorUserId) params.set("actorUserId", merged.actorUserId);
  if (merged.before) params.set("before", merged.before);
  params.set("limit", String(merged.limit));
  return params.toString();
}

export function AuditWorkspace({ workspace, filters }: { workspace: Workspace; filters: AuditFilters }) {
  const last = workspace.rows.at(-1);
  return <div className="mx-auto max-w-[1400px]">
    <header className="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between"><div><p className="text-xs font-semibold uppercase tracking-[0.12em] text-brand-500">Controleerbare mutaties</p><h1 className="mt-2 text-[30px] font-bold tracking-[-0.04em] text-brand-900 md:text-[34px]">Auditlog</h1><p className="mt-2 max-w-2xl text-sm leading-6 text-slate-500">Append-only inzicht in gevoelige en operationele acties, met actor, object, tijdstip en correlation-id.</p></div><div className="inline-flex h-10 items-center gap-2 self-start rounded-lg border border-brand-100 bg-brand-50 px-3 text-xs font-bold text-brand-700"><ShieldCheck className="size-4" />{workspace.viewerRole === "beheerder" ? "Volledige inzage" : "Operationele inzage"}</div></header>

    <section className="mt-6 rounded-xl border border-line bg-white p-5 shadow-card"><form method="get" className="grid gap-4 md:grid-cols-2 xl:grid-cols-[1fr_1.3fr_1fr_auto]"><label className="text-xs font-semibold text-ink">Categorie<select name="category" defaultValue={filters.category ?? ""} className="mt-2 h-10 w-full rounded-lg border border-line bg-white px-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100"><option value="">Alle toegestane categorieën</option>{workspace.categories.map((category) => <option key={category} value={category}>{categoryLabels[category]}</option>)}</select></label><label className="text-xs font-semibold text-ink">Exacte actie<div className="relative mt-2"><Search className="absolute left-3 top-3 size-4 text-slate-400" /><input name="action" defaultValue={filters.action ?? ""} pattern="[a-z][a-z0-9_.-]+" maxLength={100} placeholder="bijv. payment.manual.recorded" className="h-10 w-full rounded-lg border border-line pl-9 pr-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></div></label><label className="text-xs font-semibold text-ink">Actor<select name="actorUserId" defaultValue={filters.actorUserId ?? ""} className="mt-2 h-10 w-full rounded-lg border border-line bg-white px-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100"><option value="">Alle actoren</option>{workspace.actors.map((actor) => <option key={actor.id} value={actor.id}>{actor.displayName}</option>)}</select></label><div className="flex items-end gap-2"><input type="hidden" name="limit" value={filters.limit} /><button type="submit" className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-bold text-white hover:bg-brand-900"><Filter className="size-4" />Filteren</button><Link href="/backoffice/audit" className="inline-flex h-10 items-center justify-center rounded-lg border border-line px-3 text-xs font-bold text-slate-500 hover:border-brand-300">Wissen</Link></div></form></section>

    <section className="mt-6 overflow-hidden rounded-xl border border-line bg-white shadow-card"><div className="flex items-center justify-between border-b border-line px-6 py-5"><div><h2 className="text-base font-bold text-brand-900">Recente gebeurtenissen</h2><p className="mt-1 text-xs text-slate-500">Maximaal {workspace.limit} regels per pagina · nieuwste eerst</p></div><Activity className="size-5 text-brand-500" /></div>{workspace.rows.length === 0 ? <div className="px-6 py-16 text-center"><Clock3 className="mx-auto size-9 text-slate-300" /><p className="mt-4 text-sm font-bold text-slate-600">Geen auditregels gevonden</p><p className="mt-1 text-xs text-slate-400">Verruim de filters of voer eerst een geautoriseerde actie uit.</p></div> : <div className="overflow-x-auto"><table className="w-full min-w-[980px] text-left"><thead><tr className="border-b border-line bg-slate-50/70 text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400"><th className="px-6 py-3">Tijdstip</th><th className="px-3 py-3">Actie</th><th className="px-3 py-3">Actor</th><th className="px-3 py-3">Object</th><th className="px-3 py-3">Correlation-id</th><th className="px-6 py-3 text-right">Details</th></tr></thead><tbody className="divide-y divide-line">{workspace.rows.map((row) => <tr key={row.id} className="align-top hover:bg-slate-50/60"><td className="whitespace-nowrap px-6 py-4 text-[11px] text-slate-500">{formatter.format(new Date(row.createdAt))}</td><td className="px-3 py-4"><span className="rounded-full bg-brand-50 px-2.5 py-1 text-[10px] font-bold text-brand-700">{categoryLabels[row.category]}</span><code className="mt-2 block text-[11px] font-semibold text-brand-900">{row.action}</code></td><td className="px-3 py-4"><span className="flex items-center gap-2 text-xs font-semibold text-slate-700"><UserRound className="size-3.5 text-slate-400" />{row.actorName}</span></td><td className="px-3 py-4 text-[11px] text-slate-500"><span className="block font-semibold text-slate-700">{row.entityType}</span>{row.entityId && <code className="mt-1 block max-w-40 truncate" title={row.entityId}>{row.entityId}</code>}</td><td className="px-3 py-4">{row.correlationId ? <span className="flex items-center gap-1.5 text-[10px] text-slate-500"><KeyRound className="size-3" /><code className="max-w-32 truncate" title={row.correlationId}>{row.correlationId}</code></span> : <span className="text-xs text-slate-300">—</span>}</td><td className="px-6 py-4 text-right"><details className="relative inline-block text-left"><summary className="inline-flex cursor-pointer list-none items-center gap-1 text-[11px] font-bold text-brand-700 hover:text-brand-900">Bekijken<ChevronRight className="size-3.5" /></summary><pre className="mt-2 max-h-48 w-[360px] overflow-auto rounded-lg border border-line bg-slate-950 p-3 text-left text-[10px] leading-5 text-slate-100">{JSON.stringify(row.metadata, null, 2)}</pre></details></td></tr>)}</tbody></table></div>}</section>

    {last && workspace.rows.length === workspace.limit && <div className="mt-5 flex justify-end"><Link href={`/backoffice/audit?${queryString(filters, { before: last.createdAt })}`} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-brand-200 bg-white px-4 text-xs font-bold text-brand-700 hover:bg-brand-50">Oudere regels<ChevronRight className="size-4" /></Link></div>}
  </div>;
}
