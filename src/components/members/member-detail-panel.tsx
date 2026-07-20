import { Clock3, Link2, Mail, PackageCheck, ReceiptText, ShieldCheck, UserRound, X } from "lucide-react";
import Link from "next/link";
import type { MemberDetailResponse } from "@/lib/member-overview-contract";
import { cn } from "@/lib/utils";
import { OrderAdminActions } from "@/components/members/order-admin-actions";
import { MemberStatusAction } from "@/components/members/member-status-action";

const lineLabels = {
  backorder: "Nalevering",
  ready_for_pickup: "Af te halen",
  picked_up: "Afgehaald",
  cancelled: "Geannuleerd",
};
const activityLabels: Record<string, string> = {
  "payment.manual.recorded": "Handmatige betaling geregistreerd",
  "qr.created": "QR-code geactiveerd",
  "qr.rotated": "QR-code geroteerd",
  "qr.revoked": "QR-code ingetrokken",
  "stock.lines.reserved": "Voorraad toegewezen",
  "fulfilment.completed": "Uitgifte voltooid",
  "fulfilment.corrected": "Uitgifte gecorrigeerd",
  "order.created": "Bestelling aangemaakt",
  "order.updated": "Bestelling bijgewerkt",
  "member.activated": "Lid geactiveerd voor het seizoen",
  "member.deactivated": "Lid geïnactiveerd voor het seizoen",
};

function euro(cents: number) {
  return new Intl.NumberFormat("nl-NL", { style: "currency", currency: "EUR" }).format(cents / 100);
}

function moment(value: string) {
  return new Intl.DateTimeFormat("nl-NL", {
    day: "numeric",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    timeZone: "Europe/Amsterdam",
  }).format(new Date(value));
}

export function MemberDetailPanel({ detail, closeHref }: { detail: MemberDetailResponse; closeHref: string }) {
  return (
    <aside className="overflow-hidden rounded-xl border border-line bg-white shadow-card" aria-label="Liddetail">
      <div className="flex items-start justify-between gap-4 border-b border-line bg-brand-900 p-5 text-white">
        <div className="min-w-0">
          <p className="text-[10px] font-bold uppercase tracking-[0.14em] text-blue-200">Liddetail</p>
          <h2 className="mt-2 truncate text-lg font-bold">{detail.memberName}</h2>
          <p className="mt-1 text-xs text-blue-100/75">{detail.team} · {detail.relationNumber}</p>
        </div>
        <Link href={closeHref} aria-label="Sluit liddetail" className="flex size-9 shrink-0 items-center justify-center rounded-lg bg-white/10 text-blue-100 hover:bg-white/20 hover:text-white"><X className="size-4" /></Link>
      </div>

      <div className="divide-y divide-line">
        <section className="p-5">
          <div className="flex items-center justify-between gap-3"><h3 className="text-xs font-bold uppercase tracking-[0.08em] text-slate-400">Basisgegevens</h3><span className={cn("rounded-full px-2 py-1 text-[10px] font-semibold", detail.activeForSeason ? "bg-emerald-50 text-success" : "bg-slate-100 text-slate-500")}>{detail.activeForSeason ? "Actief" : "Inactief"}</span></div>
          <dl className="mt-4 space-y-3 text-xs">
            <div className="flex items-start gap-3"><Mail className="mt-0.5 size-4 shrink-0 text-brand-500" /><div><dt className="text-slate-400">E-mailadres</dt><dd className="mt-0.5 break-all font-semibold text-ink">{detail.email}</dd></div></div>
            <div className="flex items-start gap-3"><UserRound className="mt-0.5 size-4 shrink-0 text-brand-500" /><div><dt className="text-slate-400">Seizoen</dt><dd className="mt-0.5 font-semibold text-ink">{detail.activeSeason?.name ?? "Geen actief seizoen"}</dd></div></div>
          </dl>
          <MemberStatusAction memberId={detail.id} active={detail.activeForSeason} enabled={Boolean(detail.activeSeason)} />
        </section>

        {detail.order && <OrderAdminActions
          orderId={detail.order.id}
          amountDueCents={detail.order.amountDueCents}
          paid={detail.order.paymentStatus === "Betaald"}
          qrStatus={detail.order.qrStatus}
          pickedLines={detail.order.lines.filter((line) => line.status === "picked_up").map((line) => ({ id: line.id, article: line.article, size: line.size }))}
        />}

        <section className="p-5">
          <h3 className="text-xs font-bold uppercase tracking-[0.08em] text-slate-400">Bestelling</h3>
          {!detail.order ? <div className="mt-4 rounded-lg bg-slate-50 p-4 text-xs leading-5 text-slate-500">Dit lid heeft geen bestelling in het actieve seizoen.</div> : <div className="mt-4">
            <div className="grid grid-cols-2 gap-3">
              <div className="rounded-lg bg-slate-50 p-3"><p className="text-[10px] text-slate-400">Exact bedrag</p><p className="mt-1 text-sm font-bold text-brand-900">{euro(detail.order.amountDueCents)}</p></div>
              <div className="rounded-lg bg-slate-50 p-3"><p className="text-[10px] text-slate-400">Betaling</p><p className={cn("mt-1 text-xs font-bold", detail.order.paymentStatus === "Betaald" ? "text-success" : "text-warning")}>{detail.order.paymentStatus}</p></div>
            </div>
            <dl className="mt-4 space-y-2 text-xs">
              <div className="flex justify-between gap-3"><dt className="text-slate-400">Bestelstatus</dt><dd className="text-right font-semibold text-ink">{detail.order.orderStatus}</dd></div>
              <div className="flex justify-between gap-3"><dt className="text-slate-400">Betaaldatum</dt><dd className="text-right font-semibold text-ink">{detail.order.paidAt ? moment(detail.order.paidAt) : "—"}</dd></div>
              <div className="flex justify-between gap-3"><dt className="text-slate-400">QR-status</dt><dd className="text-right font-semibold text-ink">{detail.order.qrStatus}</dd></div>
            </dl>
            <div className="mt-4 space-y-2">{detail.order.lines.map((line) => <div key={line.id} className="flex items-center justify-between gap-3 rounded-lg border border-line px-3 py-2.5"><div className="min-w-0"><p className="truncate text-xs font-semibold text-ink">{line.article} · {line.size}</p><p className="mt-0.5 text-[10px] text-slate-400">{line.quantity} stuk{line.quantity === 1 ? "" : "s"}</p></div><span className="shrink-0 text-[10px] font-semibold text-brand-700">{lineLabels[line.status]}</span></div>)}</div>
          </div>}
        </section>

        <section className="p-5">
          <div className="flex items-center gap-2"><Link2 className="size-4 text-brand-500" /><h3 className="text-xs font-bold uppercase tracking-[0.08em] text-slate-400">Gekoppelde ouders</h3></div>
          {detail.parentLinks.length === 0 ? <p className="mt-3 text-xs leading-5 text-slate-500">Nog geen ouderaccount expliciet gekoppeld.</p> : <div className="mt-3 space-y-2">{detail.parentLinks.map((link) => <div key={link.id} className="rounded-lg bg-slate-50 p-3"><p className="break-all text-xs font-semibold text-ink">{link.email}</p><p className="mt-1 text-[10px] text-slate-400">Gekoppeld {moment(link.linkedAt)}</p></div>)}</div>}
        </section>

        <section className="p-5">
          <div className="flex items-center gap-2"><Clock3 className="size-4 text-brand-500" /><h3 className="text-xs font-bold uppercase tracking-[0.08em] text-slate-400">Relevante historie</h3></div>
          {detail.activities.length === 0 ? <p className="mt-3 text-xs text-slate-500">Nog geen gekoppelde operationele gebeurtenissen.</p> : <ol className="mt-3 space-y-3">{detail.activities.map((activity) => <li key={activity.id} className="flex gap-3"><div className="mt-1 flex size-7 shrink-0 items-center justify-center rounded-lg bg-brand-50 text-brand-700">{activity.action.includes("payment") ? <ReceiptText className="size-3.5" /> : activity.action.includes("fulfilment") ? <PackageCheck className="size-3.5" /> : <ShieldCheck className="size-3.5" />}</div><div><p className="text-xs font-semibold text-ink">{activityLabels[activity.action] ?? "Operationele wijziging"}</p><p className="mt-0.5 text-[10px] text-slate-400">{moment(activity.createdAt)}</p></div></li>)}</ol>}
        </section>
      </div>
    </aside>
  );
}
