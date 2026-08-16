"use client";

import { AlertTriangle, CheckCircle2, Loader2, Package, Trash2, X } from "lucide-react";
import { useRouter } from "next/navigation";
import { useEffect, useMemo, useRef, useState } from "react";
import type {
  MemberPackageBulkOptions,
  MemberPackageBulkResponse,
} from "@/lib/member-package-bulk-contract";

type Scope = "selected" | "all_active";

function euro(cents: number) {
  return new Intl.NumberFormat("nl-NL", { style: "currency", currency: "EUR" }).format(cents / 100);
}

async function postPackageAction(body: unknown) {
  const response = await fetch("/api/orders/member-packages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Duindorp-CSRF": "same-origin",
      "X-Correlation-Id": crypto.randomUUID(),
    },
    body: JSON.stringify(body),
  });
  const payload = await response.json() as MemberPackageBulkResponse & { error?: string };
  if (!response.ok) throw new Error(payload.error ?? "De pakketactie kon niet worden verwerkt.");
  return payload;
}

export function MemberPackageBulkDialog({
  open,
  initialScope,
  selectedMemberSeasonIds,
  activeCount,
  options,
  onClose,
  onCommitted,
}: {
  open: boolean;
  initialScope: Scope;
  selectedMemberSeasonIds: string[];
  activeCount: number;
  options: MemberPackageBulkOptions;
  onClose: () => void;
  onCommitted: () => void;
}) {
  const router = useRouter();
  const closeButton = useRef<HTMLButtonElement>(null);
  const [scope, setScope] = useState<Scope>(initialScope);
  const [action, setAction] = useState<"assign" | "remove">("assign");
  const [packageRevisionId, setPackageRevisionId] = useState(
    options.packages.find((item) => item.default)?.revisionId ?? options.packages[0]?.revisionId ?? "",
  );
  const [reason, setReason] = useState("");
  const [requestId, setRequestId] = useState("");
  const [preview, setPreview] = useState<MemberPackageBulkResponse | null>(null);
  const [notice, setNotice] = useState<{ tone: "error" | "success"; text: string } | null>(null);
  const [confirmedRemoval, setConfirmedRemoval] = useState(false);
  const [busy, setBusy] = useState(false);
  const selectedPackage = useMemo(
    () => options.packages.find((item) => item.revisionId === packageRevisionId) ?? null,
    [options.packages, packageRevisionId],
  );

  useEffect(() => {
    if (!open) return;
    setScope(initialScope);
    setRequestId(crypto.randomUUID());
    setPreview(null);
    setNotice(null);
    setConfirmedRemoval(false);
    queueMicrotask(() => closeButton.current?.focus());
  }, [initialScope, open]);

  useEffect(() => {
    if (!open) return;
    function keydown(event: KeyboardEvent) {
      if (event.key === "Escape" && !busy) onClose();
    }
    document.addEventListener("keydown", keydown);
    return () => document.removeEventListener("keydown", keydown);
  }, [busy, onClose, open]);

  function invalidate() {
    setPreview(null);
    setNotice(null);
    setConfirmedRemoval(false);
  }

  async function run(commit: boolean) {
    setBusy(true);
    setNotice(null);
    try {
      const result = await postPackageAction({
        action,
        scope,
        memberSeasonIds: scope === "selected" ? selectedMemberSeasonIds : [],
        packageRevisionId: action === "assign" ? packageRevisionId : null,
        reason,
        requestId,
        commit,
        previewToken: commit ? preview?.previewToken : undefined,
      });
      setPreview(result);
      if (commit) {
        setNotice({
          tone: "success",
          text: `${result.changedCount ?? 0} pakketactie(s) uitgevoerd. ${result.unchangedCount} ongewijzigd en ${result.blockedCount + result.inactiveOrInvalidCount} overgeslagen of geblokkeerd.`,
        });
        setRequestId(crypto.randomUUID());
        onCommitted();
        router.refresh();
      }
    } catch (error) {
      setNotice({ tone: "error", text: error instanceof Error ? error.message : "De pakketactie kon niet worden verwerkt." });
      if (commit) setPreview(null);
    } finally {
      setBusy(false);
    }
  }

  if (!open) return null;
  const scopeCount = scope === "selected" ? selectedMemberSeasonIds.length : activeCount;
  const canPreview = reason.trim().length >= 3
    && scopeCount > 0
    && (action === "remove" || Boolean(packageRevisionId));
  const canCommit = Boolean(preview?.previewToken)
    && !preview?.committed
    && (preview?.eligibleCount ?? 0) > 0
    && (action !== "remove" || confirmedRemoval);

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center bg-brand-950/50 p-0 sm:items-center sm:p-6" role="presentation">
      <section role="dialog" aria-modal="true" aria-labelledby="member-package-dialog-title" aria-describedby="member-package-dialog-description" className="max-h-[92vh] w-full max-w-2xl overflow-y-auto rounded-t-2xl bg-white shadow-2xl sm:rounded-2xl">
        <header className="flex items-start justify-between gap-4 border-b border-line px-5 py-5">
          <div>
            <h2 id="member-package-dialog-title" className="text-lg font-bold text-brand-900">Pakketten bij leden beheren</h2>
            <p id="member-package-dialog-description" className="mt-1 text-xs leading-5 text-slate-500">Controleer eerst wie veilig kan worden gewijzigd. Betaling, reservering of uitgifte blokkeert gewone verwijdering of wisseling.</p>
          </div>
          <button ref={closeButton} type="button" onClick={onClose} disabled={busy} aria-label="Dialoog sluiten" className="inline-flex size-9 shrink-0 items-center justify-center rounded-lg text-slate-400 hover:bg-slate-100 disabled:opacity-40"><X className="size-4" /></button>
        </header>

        <div className="space-y-5 p-5">
          <fieldset disabled={busy} className="grid gap-2 sm:grid-cols-2">
            <legend className="mb-2 text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400">Leden</legend>
            <label className="flex min-h-12 items-center gap-3 rounded-lg border border-line px-3 text-xs font-semibold text-ink"><input type="radio" name="package-scope" checked={scope === "selected"} disabled={selectedMemberSeasonIds.length === 0} onChange={() => { setScope("selected"); invalidate(); }} className="text-brand-700 focus:ring-brand-500" /> Geselecteerd ({selectedMemberSeasonIds.length})</label>
            <label className="flex min-h-12 items-center gap-3 rounded-lg border border-line px-3 text-xs font-semibold text-ink"><input type="radio" name="package-scope" checked={scope === "all_active"} onChange={() => { setScope("all_active"); invalidate(); }} className="text-brand-700 focus:ring-brand-500" /> Alle actieve leden ({activeCount})</label>
          </fieldset>

          <fieldset disabled={busy} className="grid gap-2 sm:grid-cols-2">
            <legend className="mb-2 text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400">Actie</legend>
            <label className="flex min-h-12 items-center gap-3 rounded-lg border border-line px-3 text-xs font-semibold text-ink"><input type="radio" name="package-action" checked={action === "assign"} onChange={() => { setAction("assign"); invalidate(); }} className="text-brand-700 focus:ring-brand-500" /><Package className="size-4 text-brand-600" /> Toewijzen of veilig wijzigen</label>
            <label className="flex min-h-12 items-center gap-3 rounded-lg border border-line px-3 text-xs font-semibold text-ink"><input type="radio" name="package-action" checked={action === "remove"} onChange={() => { setAction("remove"); invalidate(); }} className="text-brand-700 focus:ring-brand-500" /><Trash2 className="size-4 text-danger" /> Pakket verwijderen</label>
          </fieldset>

          {action === "assign" && <label className="block text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400">Pakket<select value={packageRevisionId} disabled={busy} onChange={(event) => { setPackageRevisionId(event.target.value); invalidate(); }} className="mt-2 h-11 w-full rounded-lg border border-line bg-white px-3 text-sm text-ink outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100"><option value="">Kies een pakket</option>{options.packages.map((item) => <option key={item.revisionId} value={item.revisionId}>{item.name} · revisie {item.revisionNumber} · {euro(item.priceCents)}{item.default ? " · standaard" : ""}</option>)}</select>{selectedPackage && <span className="mt-2 block font-normal normal-case tracking-normal text-slate-500">{selectedPackage.itemCount} product(en); maten komen uitsluitend uit het bevestigde lidprofiel.</span>}</label>}

          <label className="block text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400">Beheerreden<textarea value={reason} disabled={busy} onChange={(event) => { setReason(event.target.value); invalidate(); }} maxLength={500} rows={3} className="mt-2 w-full rounded-lg border border-line bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-ink outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" placeholder="Waarom wordt deze pakketactie uitgevoerd?" /></label>

          {preview && !preview.committed && <section className="rounded-xl border border-brand-100 bg-brand-50 p-4" aria-live="polite"><h3 className="text-xs font-bold text-brand-900">Voorcontrole gereed</h3><div className="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-4"><Metric label="Geschikt" value={preview.eligibleCount} /><Metric label="Ongewijzigd" value={preview.unchangedCount} /><Metric label="Geblokkeerd" value={preview.blockedCount} /><Metric label="Niet actief/geldig" value={preview.inactiveOrInvalidCount} /></div>{action === "assign" && <p className="mt-3 text-[11px] leading-5 text-brand-800">{preview.linkedSizeCount} pakketcomponent(en) krijgen direct de bevestigde maat. Voor {preview.missingSizeCount} component(en) ontbreekt nog een bevestigde geldige maat; die blijven zonder voorraadregel tot bevestiging.</p>}{action === "remove" && <label className="mt-3 flex items-start gap-2 text-[11px] leading-5 text-brand-900"><input type="checkbox" checked={confirmedRemoval} onChange={(event) => setConfirmedRemoval(event.target.checked)} className="mt-0.5 size-4 rounded border-brand-300 text-brand-700 focus:ring-brand-500" /> Ik bevestig dat alleen de als geschikt getoonde, nog onbetaalde en niet-gereserveerde pakketten worden ingetrokken. Historie blijft bewaard.</label>}</section>}

          {notice && <div role={notice.tone === "error" ? "alert" : "status"} className={`flex items-start gap-2 rounded-lg border p-3 text-xs leading-5 ${notice.tone === "error" ? "border-red-100 bg-red-50 text-danger" : "border-emerald-100 bg-emerald-50 text-success"}`}>{notice.tone === "error" ? <AlertTriangle className="mt-0.5 size-4 shrink-0" /> : <CheckCircle2 className="mt-0.5 size-4 shrink-0" />}{notice.text}</div>}
        </div>

        <footer className="flex flex-col-reverse gap-2 border-t border-line bg-slate-50 px-5 py-4 sm:flex-row sm:justify-end"><button type="button" onClick={onClose} disabled={busy} className="inline-flex h-10 items-center justify-center rounded-lg border border-line bg-white px-4 text-xs font-semibold text-slate-600 hover:border-brand-500 disabled:opacity-40">Sluiten</button><button type="button" onClick={() => void run(false)} disabled={busy || !canPreview} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-brand-200 bg-white px-4 text-xs font-semibold text-brand-700 hover:border-brand-500 disabled:cursor-not-allowed disabled:opacity-40">{busy ? <Loader2 className="size-4 animate-spin" /> : null} Voorcontrole uitvoeren</button><button type="button" onClick={() => void run(true)} disabled={busy || !canCommit} className={`inline-flex h-10 items-center justify-center gap-2 rounded-lg px-4 text-xs font-semibold text-white disabled:cursor-not-allowed disabled:opacity-40 ${action === "remove" ? "bg-red-700 hover:bg-red-800" : "bg-brand-700 hover:bg-brand-900"}`}>{action === "remove" ? <Trash2 className="size-4" /> : <CheckCircle2 className="size-4" />} Definitief uitvoeren</button></footer>
      </section>
    </div>
  );
}

function Metric({ label, value }: { label: string; value: number }) {
  return <div><p className="text-xl font-bold text-brand-900">{value.toLocaleString("nl-NL")}</p><p className="mt-0.5 text-[9px] font-semibold uppercase tracking-[0.08em] text-brand-500">{label}</p></div>;
}
