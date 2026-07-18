import { AlertTriangle, Banknote, CheckCircle2, Clock3, CreditCard, ReceiptText, RotateCcw } from "lucide-react";
import type { PaymentWorkspace as Workspace } from "@/lib/payment-workspace-contract";

const money = new Intl.NumberFormat("nl-NL", { style: "currency", currency: "EUR" });
const date = new Intl.DateTimeFormat("nl-NL", { dateStyle: "short", timeStyle: "short" });
const statusLabel: Record<Workspace["attempts"][number]["status"], string> = {
  open: "Open", pending: "In behandeling", paid: "Betaald", failed: "Mislukt",
  canceled: "Geannuleerd", expired: "Verlopen", refunded: "Terugbetaald", duplicate_paid: "Dubbel betaald",
};
const methodLabel = { cash: "Kas", card: "Pin", mollie: "Mollie" } as const;

export function PaymentWorkspace({ workspace }: { workspace: Workspace }) {
  const attention = workspace.summary.review + workspace.summary.duplicatePaid + workspace.summary.refunded;
  return <div className="mx-auto max-w-[1400px]">
    <header><p className="text-xs font-semibold uppercase tracking-[0.12em] text-brand-500">Financiële operatie</p><h1 className="mt-2 text-[30px] font-bold tracking-[-0.04em] text-brand-900 md:text-[34px]">Betalingen</h1><p className="mt-2 max-w-2xl text-sm leading-6 text-slate-500">Controleer exacte betalingen per bestelling, providerreconciliatie en uitzonderingen die handmatige aandacht vereisen.</p></header>
    <section className="mt-6 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
      <Metric icon={Clock3} label="Open of onderweg" value={workspace.summary.open + workspace.summary.pending} detail="Nog niet definitief betaald" />
      <Metric icon={CheckCircle2} label="Betaald" value={workspace.summary.paid} detail="Exact toegepast per bestelling" />
      <Metric icon={RotateCcw} label="Refund of dubbel" value={workspace.summary.refunded + workspace.summary.duplicatePaid} detail="QR fail-closed waar vereist" />
      <Metric icon={AlertTriangle} label="Aandacht nodig" value={attention} detail="Controleer reconciliatie" danger={attention > 0} />
    </section>
    {attention > 0 && <div role="status" className="mt-6 flex gap-3 rounded-xl border border-amber-200 bg-amber-50 p-4 text-xs leading-5 text-amber-900"><AlertTriangle className="mt-0.5 size-4 shrink-0" aria-hidden="true" /><p><strong>Handmatige controle nodig.</strong> Afwijkingen veranderen een bestelling nooit automatisch naar betaald. Refunds blokkeren actieve QR-toegang zonder bestaande uitgiftehistorie te herschrijven.</p></div>}
    <section className="mt-6 overflow-hidden rounded-xl border border-line bg-white shadow-card">
      <div className="border-b border-line px-6 py-5"><h2 className="text-base font-bold text-brand-900">Recente betaalpogingen</h2><p className="mt-1 text-xs text-slate-500">Maximaal 100 records; e-mailadressen, checkoutlinks en providerpayloads worden niet getoond.</p></div>
      {workspace.attempts.length === 0 ? <div className="px-6 py-16 text-center"><ReceiptText className="mx-auto size-9 text-slate-300" aria-hidden="true" /><p className="mt-4 text-sm font-bold text-slate-600">Nog geen betalingen</p><p className="mt-1 text-xs text-slate-400">Kas-, pin- en Molliebetalingen verschijnen hier zodra ze worden geregistreerd.</p></div> : <div className="overflow-x-auto"><table className="w-full min-w-[980px] text-left"><thead><tr className="border-b border-line bg-slate-50/70 text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400"><th className="px-6 py-3">Lid</th><th className="px-3 py-3">Methode</th><th className="px-3 py-3">Status</th><th className="px-3 py-3">Bedrag</th><th className="px-3 py-3">Reconciliatie</th><th className="px-6 py-3 text-right">Aangemaakt</th></tr></thead><tbody className="divide-y divide-line">{workspace.attempts.map((payment) => <tr key={payment.paymentId} className="align-top"><td className="px-6 py-4"><p className="text-xs font-bold text-brand-900">{payment.memberName}</p><p className="mt-1 text-[10px] text-slate-400">{payment.relationNumber} · {payment.team}</p></td><td className="px-3 py-4 text-xs font-semibold text-slate-600"><span className="inline-flex items-center gap-1.5">{payment.method === "cash" ? <Banknote className="size-3.5" /> : <CreditCard className="size-3.5" />}{methodLabel[payment.method]}</span></td><td className="px-3 py-4"><Status status={payment.status} /></td><td className="px-3 py-4 text-xs font-bold text-brand-900">{money.format(payment.amountCents / 100)}</td><td className="max-w-xs px-3 py-4">{payment.reconciliationIssue ? <p className="text-[11px] leading-5 text-danger">{payment.reconciliationIssue}</p> : <p className="text-[11px] text-slate-400">{payment.reconciledAt ? `Gecontroleerd ${date.format(new Date(payment.reconciledAt))}` : "Nog geen providercontrole"}</p>}</td><td className="px-6 py-4 text-right text-[11px] text-slate-400">{date.format(new Date(payment.createdAt))}</td></tr>)}</tbody></table></div>}
    </section>
  </div>;
}

function Metric({ icon: Icon, label, value, detail, danger = false }: { icon: typeof Clock3; label: string; value: number; detail: string; danger?: boolean }) {
  return <div className="rounded-xl border border-line bg-white p-5 shadow-card"><div className="flex items-center justify-between"><p className="text-[10px] font-bold uppercase tracking-[0.1em] text-slate-400">{label}</p><span className={`flex size-8 items-center justify-center rounded-lg ${danger ? "bg-red-50 text-danger" : "bg-brand-50 text-brand-700"}`}><Icon className="size-4" aria-hidden="true" /></span></div><p className={`mt-3 text-2xl font-bold ${danger ? "text-danger" : "text-brand-900"}`}>{value.toLocaleString("nl-NL")}</p><p className="mt-1 text-[11px] text-slate-400">{detail}</p></div>;
}

function Status({ status }: { status: Workspace["attempts"][number]["status"] }) {
  const danger = ["failed", "refunded", "duplicate_paid"].includes(status);
  const success = status === "paid";
  return <span className={`inline-flex rounded-full px-2 py-1 text-[10px] font-bold ${danger ? "bg-red-50 text-danger" : success ? "bg-emerald-50 text-success" : "bg-amber-50 text-amber-700"}`}>{statusLabel[status]}</span>;
}
