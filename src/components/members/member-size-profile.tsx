"use client";

import { AlertTriangle, CheckCircle2, Loader2, Ruler, Save } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import type { MemberSizeProfile as Profile } from "@/lib/member-overview-contract";

const statusLabels = {
  backorder: "Nalevering",
  ready_for_pickup: "Af te halen",
  picked_up: "Afgehaald",
  cancelled: "Geannuleerd",
};

const IMPORT_CONFIRMATION_REASON = "Geïmporteerde maat bevestigd";

export function MemberSizeProfile({ memberId, profile: initialProfile }: { memberId: string; profile: Profile | null }) {
  const router = useRouter();
  const [profile, setProfile] = useState(initialProfile);
  const [draft, setDraft] = useState<Record<string, string>>(() => Object.fromEntries(initialProfile?.articles.map((article) => [article.id, article.selectedVariantId ?? ""]) ?? []));
  const [saving, setSaving] = useState(false);
  const [reason, setReason] = useState("");
  const [releaseConfirmed, setReleaseConfirmed] = useState(false);
  const [requestId, setRequestId] = useState(() => crypto.randomUUID());
  const [notice, setNotice] = useState<{ tone: "success" | "error"; text: string } | null>(null);

  useEffect(() => {
    setProfile(initialProfile);
    setDraft(Object.fromEntries(initialProfile?.articles.map((article) => [article.id, article.selectedVariantId ?? ""]) ?? []));
  }, [initialProfile]);

  const variantChanges = useMemo(() => profile?.articles.filter((article) => article.editable && (draft[article.id] ?? "") !== (article.selectedVariantId ?? "")) ?? [], [draft, profile]);
  const confirmations = useMemo(() => profile?.articles.filter((article) => article.editable
    && article.selectionStatus === "imported_unconfirmed"
    && Boolean(article.selectedVariantId)
    && (draft[article.id] ?? "") === article.selectedVariantId) ?? [], [draft, profile]);
  const pendingUpdates = useMemo(() => [...variantChanges, ...confirmations], [confirmations, variantChanges]);
  const changedArticleIds = useMemo(() => new Set(variantChanges.map((article) => article.id)), [variantChanges]);
  const confirmationOnly = confirmations.length > 0 && variantChanges.length === 0;
  const releasesReservation = variantChanges.some((article) => article.hasReservation);

  async function save() {
    if (!profile || !profile.editable || pendingUpdates.length === 0) return;
    if (pendingUpdates.length > 25) {
      setNotice({ tone: "error", text: "Sla maximaal 25 gewijzigde of te bevestigen artikelen tegelijk op." });
      return;
    }
    if (variantChanges.length > 0 && reason.trim().length < 3) {
      setNotice({ tone: "error", text: "Vul een korte reden voor de maatwijziging in." });
      return;
    }
    if (releasesReservation && !releaseConfirmed) {
      setNotice({ tone: "error", text: "Bevestig dat de bestaande voorraadreservering mag worden vrijgegeven." });
      return;
    }
    setSaving(true);
    setNotice(null);
    try {
      const response = await fetch("/api/members/sizes", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" },
        body: JSON.stringify({
          memberId,
          memberSeasonId: profile.memberSeasonId,
          revision: profile.revision,
          reason: confirmationOnly ? IMPORT_CONFIRMATION_REASON : reason,
          requestId,
          sizes: pendingUpdates.map((article) => ({ articleId: article.id, variantId: draft[article.id] || null, releaseReserved: changedArticleIds.has(article.id) && article.hasReservation })),
        }),
      });
      const payload = await response.json() as { error?: string; sizeProfile?: Profile };
      if (!response.ok || !payload.sizeProfile) throw new Error(payload.error ?? "De kledingmaten konden niet worden opgeslagen.");
      setProfile(payload.sizeProfile);
      setDraft(Object.fromEntries(payload.sizeProfile.articles.map((article) => [article.id, article.selectedVariantId ?? ""])));
      setReason("");
      setReleaseConfirmed(false);
      setRequestId(crypto.randomUUID());
      setNotice({ tone: "success", text: confirmationOnly ? "De geïmporteerde kledingmaten zijn bevestigd en geaudit." : "De kledingmaten zijn opgeslagen en geaudit." });
      router.refresh();
    } catch (error) {
      setNotice({ tone: "error", text: error instanceof Error ? error.message : "De kledingmaten konden niet worden opgeslagen." });
    } finally {
      setSaving(false);
    }
  }

  return <section className="p-5">
    <div className="flex items-start justify-between gap-3"><div className="flex items-center gap-2"><Ruler className="size-4 text-brand-500" /><div><h3 className="text-xs font-bold uppercase tracking-[0.08em] text-slate-400">Kledingmaten</h3><p className="mt-1 text-[10px] text-slate-400">Doorgegeven maten per artikel en seizoen</p></div></div>{profile && <span className="rounded-full bg-brand-50 px-2 py-1 text-[9px] font-bold text-brand-700">{profile.seasonName}</span>}</div>
    {!profile ? <p className="mt-4 rounded-lg bg-amber-50 p-4 text-xs leading-5 text-amber-800">Stel eerst een open actief seizoen in om kledingmaten vast te leggen.</p> : profile.articles.length === 0 ? <p className="mt-4 rounded-lg bg-slate-50 p-4 text-xs leading-5 text-slate-500">Koppel eerst actieve artikelen en maten aan dit seizoen.</p> : <>
      {!profile.editable && <p className="mt-4 rounded-lg bg-amber-50 p-3 text-xs leading-5 text-amber-800">Dit lid of seizoen is niet actief; maten zijn daarom alleen-lezen.</p>}
      {notice && <div role={notice.tone === "error" ? "alert" : "status"} className={`mt-4 flex gap-2 rounded-lg border p-3 text-xs ${notice.tone === "error" ? "border-red-100 bg-red-50 text-danger" : "border-emerald-100 bg-emerald-50 text-success"}`}>{notice.tone === "error" ? <AlertTriangle className="size-4 shrink-0" /> : <CheckCircle2 className="size-4 shrink-0" />}{notice.text}</div>}
      <div className="mt-4 space-y-3">{profile.articles.map((article) => <div key={article.id} className="rounded-lg border border-line p-3"><div className="flex items-center justify-between gap-3"><div className="min-w-0"><p className="truncate text-xs font-bold text-ink">{article.name}</p><p className="mt-0.5 text-[9px] text-slate-400">{article.code}</p></div>{article.ordered && <span className="shrink-0 rounded-full bg-emerald-50 px-2 py-1 text-[9px] font-bold text-success">Besteld{article.orderLineStatus ? ` · ${statusLabels[article.orderLineStatus]}` : ""}</span>}</div><label className="mt-3 block text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400">Maat<select aria-label={`Maat ${article.name}`} value={draft[article.id] ?? ""} onChange={(event) => { setDraft((current) => ({ ...current, [article.id]: event.target.value })); setReleaseConfirmed(false); setNotice(null); }} disabled={!article.editable || saving} className="mt-2 h-10 w-full rounded-lg border border-line bg-white px-3 text-xs text-ink outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100 disabled:bg-slate-50 disabled:text-slate-500"><option value="" disabled={article.ordered}>Niet vastgelegd</option>{article.variants.map((variant) => <option key={variant.id} value={variant.id}>{variant.size}{!variant.active ? " · niet meer actief" : ""}</option>)}</select></label><div className="mt-2 flex flex-wrap gap-1.5 text-[9px]"><span className="rounded-full bg-slate-100 px-2 py-1 text-slate-600">{article.selectionStatus === "imported_unconfirmed" ? "Geïmporteerd · nog bevestigen" : article.selectionStatus === "confirmed" ? "Bevestigd" : article.selectionStatus === "conflict" ? "Maatconflict" : article.selectionStatus === "change_requested" ? "Wijziging aangevraagd" : article.selectionStatus === "locked" ? "Uitgegeven · vergrendeld" : "Niet vastgelegd"}</span>{article.selectionSource && <span className="rounded-full bg-brand-50 px-2 py-1 text-brand-700">Bron: {article.selectionSource === "import" ? "Sportlink" : article.selectionSource === "parent" ? "ouder/lid" : article.selectionSource === "staff" ? "beheer" : article.selectionSource === "order" ? "bestelling" : "bestaande registratie"}</span>}</div>{article.rawValue && <p className="mt-2 text-[10px] leading-4 text-amber-800">Bronwaarde: {article.rawValue}{article.memberNote ? ` · ${article.memberNote}` : ""}</p>}{article.editBlockReason === "issued" && <p className="mt-2 text-[10px] leading-4 text-slate-500">Deze maat is uitgegeven en blijft historisch vergrendeld.</p>}{article.editBlockReason === "reserved_admin_required" && <p className="mt-2 text-[10px] leading-4 text-amber-800">Alleen een beheerder kan deze reservering geauditeerd vrijgeven en de maat wijzigen.</p>}{article.hasReservation && article.editable && <p className="mt-2 text-[10px] leading-4 text-amber-800">Wijzigen geeft de huidige voorraadreservering vrij. De nieuwe maat gaat terug naar de wachtlijst.</p>}</div>)}</div>
      {pendingUpdates.length > 0 && <div className="mt-4 space-y-3 rounded-lg border border-brand-100 bg-brand-50/40 p-3">{confirmations.length > 0 && <p className="text-[10px] leading-4 text-brand-900">{confirmationOnly ? "De ingevulde geïmporteerde maten worden ongewijzigd bevestigd." : "Ongewijzigde geïmporteerde maten worden tegelijk bevestigd."}</p>}{variantChanges.length > 0 && <label className="block text-[10px] font-bold uppercase tracking-[0.08em] text-slate-500">Reden<textarea rows={2} minLength={3} maxLength={500} value={reason} onChange={(event) => { setReason(event.target.value); setNotice(null); }} placeholder="Bijvoorbeeld: gecorrigeerd na passen" className="mt-2 w-full rounded-lg border border-line bg-white px-3 py-2 text-xs font-normal normal-case tracking-normal text-ink outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></label>}{releasesReservation && <label className="flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 p-3 text-[10px] leading-4 text-amber-900"><input type="checkbox" checked={releaseConfirmed} onChange={(event) => setReleaseConfirmed(event.target.checked)} className="mt-0.5 size-4" /><span>Ik bevestig dat de bestaande reservering wordt vrijgegeven. De nieuwe maat krijgt pas opnieuw voorraad volgens de wachtlijst.</span></label>}</div>}
      <div className="mt-4 flex justify-end"><button type="button" onClick={() => void save()} disabled={!profile.editable || saving || pendingUpdates.length === 0} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-bold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:opacity-50">{saving ? <Loader2 className="size-4 animate-spin" /> : <Save className="size-4" />}{confirmationOnly ? "Maten bevestigen" : "Maten opslaan"}</button></div>
    </>}
  </section>;
}
