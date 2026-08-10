"use client";

import { AlertTriangle, CheckCircle2, CircleOff, ClipboardList, Loader2, LockKeyhole, PackageCheck, Search, Shirt, UsersRound } from "lucide-react";
import { FormEvent, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { formatCentsForEuroInput, parseEuroAmountToCents, type CatalogOrderWorkspace as Workspace } from "@/lib/catalog-order-contract";
import type { PackageChangeResponse } from "@/lib/package-change-contract";
import { TeamArticleBulkPanel } from "@/components/orders/team-article-bulk-panel";

type Member = Workspace["members"][number];
type Article = Workspace["articles"][number];
type PackageOrder = Workspace["packageOrders"][number];
type PackageRevision = Workspace["packageRevisions"][number];
type PackageSizeChange = Workspace["packageSizeChangeRequests"][number];
type DraftLine = { articleId: string; variantId: string; quantity: number };
type Notice = { tone: "error" | "success"; text: string } | null;

const fieldClass = "h-11 w-full rounded-lg border border-line bg-white px-3 text-sm outline-none transition focus:border-brand-500 focus:ring-2 focus:ring-brand-100 disabled:bg-slate-50 disabled:text-slate-400";
const lineStatusLabels = { backorder: "Nalevering", ready_for_pickup: "Af te halen", picked_up: "Afgehaald", cancelled: "Geannuleerd" } as const;

async function saveOrder(body: unknown) {
  const response = await fetch("/api/orders/save", { method: "POST", headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" }, body: JSON.stringify(body) });
  const payload = await response.json() as { error?: string };
  if (!response.ok) throw new Error(payload.error ?? "De bestelling kon niet worden opgeslagen.");
}

async function postMutation<T = void>(
  path: string,
  body: unknown,
): Promise<T> {
  const response = await fetch(path, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Duindorp-CSRF": "same-origin",
    },
    body: JSON.stringify(body),
  });
  const payload = await response.json() as T & { error?: string };
  if (!response.ok) {
    throw new Error(payload.error ?? "De wijziging kon niet worden verwerkt.");
  }
  return payload;
}

export function isLegacyOrder(
  member: Member,
  packageOrder: PackageOrder | null,
) {
  return Boolean(member.order && !packageOrder?.packageRevisionId);
}

export function requestedSizeLabel(request: PackageSizeChange) {
  return request.requestedKind === "variant"
    ? request.requestedSize ?? "Onbekende maat"
    : request.requestedRawValue ?? "Anders…";
}

export function OrdersWorkspace({
  workspace,
  canManagePackages,
}: {
  workspace: Workspace;
  canManagePackages: boolean;
}) {
  const router = useRouter();
  const [search, setSearch] = useState("");
  const [memberId, setMemberId] = useState<string | null>(null);
  const [amount, setAmount] = useState(workspace.activeSeason ? formatCentsForEuroInput(workspace.activeSeason.defaultAmountCents) : "0,00");
  const [lines, setLines] = useState<DraftLine[]>([]);
  const [notice, setNotice] = useState<Notice>(null);
  const [saving, setSaving] = useState(false);
  const selected = workspace.members.find((member) => member.id === memberId) ?? null;
  const selectedPackageOrder = selected
    ? workspace.packageOrders.find((order) => order.memberId === selected.id) ?? null
    : null;
  const selectedHasLegacyOrder = selected
    ? isLegacyOrder(selected, selectedPackageOrder)
    : false;

  const filteredMembers = useMemo(() => {
    const query = search.trim().toLocaleLowerCase("nl-NL");
    if (!query) return workspace.members;
    return workspace.members.filter((member) => [member.name, member.relationNumber, member.team].some((value) => value?.toLocaleLowerCase("nl-NL").includes(query)));
  }, [search, workspace.members]);

  const editableArticles = useMemo(() => {
    if (!workspace.activeSeason) return [];
    const current = workspace.articles.filter((article) => article.active && article.seasonIds.includes(workspace.activeSeason!.id));
    const existingIds = new Set(selected?.order?.lines.map((line) => line.articleId) ?? []);
    return workspace.articles.filter((article) => current.some((item) => item.id === article.id) || existingIds.has(article.id));
  }, [selected, workspace.activeSeason, workspace.articles]);

  useEffect(() => {
    if (!selected) return;
    setAmount(formatCentsForEuroInput(selected.order?.amountDueCents ?? workspace.activeSeason?.defaultAmountCents ?? 0));
    setLines((selected.order?.lines ?? []).map((line) => ({ articleId: line.articleId, variantId: line.variantId, quantity: line.quantity })));
    setNotice(null);
  }, [selected, workspace.activeSeason?.defaultAmountCents]);

  function chooseMember(member: Member) {
    setMemberId(member.id);
  }

  function updateLine(articleId: string, variantId: string) {
    setLines((current) => {
      const withoutArticle = current.filter((line) => line.articleId !== articleId);
      return variantId ? [...withoutArticle, { articleId, variantId, quantity: current.find((line) => line.articleId === articleId)?.quantity ?? 1 }] : withoutArticle;
    });
  }

  function updateQuantity(articleId: string, quantity: number) {
    setLines((current) => current.map((line) => line.articleId === articleId ? { ...line, quantity } : line));
  }

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (!selected || !workspace.activeSeason || selected.order?.paid) return;
    const amountDueCents = parseEuroAmountToCents(amount);
    if (amountDueCents === null) {
      setNotice({ tone: "error", text: "Voer een exact bedrag in met maximaal twee decimalen, bijvoorbeeld 87,50." });
      return;
    }
    if (lines.length === 0) {
      setNotice({ tone: "error", text: "Selecteer minimaal één artikelvariant." });
      return;
    }
    setSaving(true);
    setNotice(null);
    try {
      await saveOrder({ memberId: selected.id, seasonId: workspace.activeSeason.id, amountDueCents, lines: lines.map((line) => ({ variantId: line.variantId, quantity: line.quantity })) });
      setNotice({ tone: "success", text: selected.order ? "Bestelling bijgewerkt en geaudit." : "Bestelling aangemaakt met het exacte verschuldigde bedrag." });
      router.refresh();
    } catch (error) {
      setNotice({ tone: "error", text: error instanceof Error ? error.message : "De bestelling kon niet worden opgeslagen." });
    } finally {
      setSaving(false);
    }
  }

  const counts = {
    total: workspace.members.length,
    ordered: workspace.members.filter((member) => member.order).length,
    paid: workspace.members.filter((member) => member.order?.paid).length,
  };

  return <div className="mx-auto max-w-[1400px]">
    <header><p className="text-xs font-semibold uppercase tracking-[0.12em] text-brand-500">Orderbeheer</p><h1 className="mt-2 text-[30px] font-bold tracking-[-0.04em] text-brand-900 md:text-[34px]">Bestellingen</h1><p className="mt-2 text-sm text-slate-500">Beheer per actief lid precies één seizoensbestelling met een exact verschuldigd bedrag.</p></header>

    {!workspace.activeSeason && <div className="mt-6 rounded-xl border border-amber-200 bg-amber-50 p-5"><h2 className="text-sm font-bold text-amber-900">Geen open actief seizoen</h2><p className="mt-1 text-xs leading-5 text-amber-800">Nieuwe of gewijzigde bestellingen zijn geblokkeerd totdat een open seizoen actief is.</p></div>}
    {notice && <div role={notice.tone === "error" ? "alert" : "status"} className={"mt-6 flex items-start gap-2 rounded-xl border p-4 text-xs " + (notice.tone === "error" ? "border-red-100 bg-red-50 text-danger" : "border-emerald-100 bg-emerald-50 text-success")}>{notice.tone === "error" ? <AlertTriangle className="size-4 shrink-0" /> : <CheckCircle2 className="size-4 shrink-0" />}{notice.text}</div>}

    <section className="mt-6 grid gap-4 sm:grid-cols-3">
      {[{ label: "Actieve leden", value: counts.total }, { label: "Met bestelling", value: counts.ordered }, { label: "Betaald", value: counts.paid }].map((metric) => <div key={metric.label} className="rounded-xl border border-line bg-white px-5 py-4 shadow-card"><p className="text-[10px] font-bold uppercase tracking-[0.1em] text-slate-400">{metric.label}</p><p className="mt-2 text-2xl font-bold text-brand-900">{metric.value.toLocaleString("nl-NL")}</p></div>)}
    </section>

    {canManagePackages && workspace.packageSizeChangeRequests.length > 0 && (
      <PackageSizeChangesPanel
        requests={workspace.packageSizeChangeRequests}
        onResolved={(message) => {
          setNotice({ tone: "success", text: message });
          router.refresh();
        }}
      />
    )}

    {!workspace.packageFeatureEnabled ? (
      <TeamArticleBulkPanel
        teams={workspace.teamOptions}
        articles={workspace.activeSeason ? workspace.articles.filter((article) => article.active && article.seasonIds.includes(workspace.activeSeason!.id)).map((article) => ({ ...article, variants: article.variants.filter((variant) => variant.active) })).filter((article) => article.variants.length > 0) : []}
        disabled={!workspace.activeSeason}
      />
    ) : (
      <div className="mt-6 rounded-xl border border-brand-100 bg-brand-50 p-5 text-xs leading-5 text-brand-800">
        Nieuwe bestellingen worden als commercieel pakket aangemaakt. Bestaande
        losse artikelbestellingen blijven uitsluitend als historische
        compatibiliteitsflow beschikbaar.
      </div>
    )}

    <div className="mt-6 grid items-start gap-6 xl:grid-cols-[390px_minmax(0,1fr)]">
      <aside className="overflow-hidden rounded-xl border border-line bg-white shadow-card">
        <div className="border-b border-line p-5"><h2 className="text-sm font-bold text-brand-900">Actieve leden</h2><label className="relative mt-4 block"><span className="sr-only">Zoek lid</span><Search className="absolute left-3 top-1/2 size-4 -translate-y-1/2 text-slate-400" /><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Naam, team of relatienummer" className="h-10 w-full rounded-lg border border-line pl-9 pr-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100" /></label></div>
        {filteredMembers.length === 0 ? <div className="px-6 py-16 text-center"><CircleOff className="mx-auto size-8 text-slate-300" /><p className="mt-4 text-sm font-semibold text-slate-600">Geen leden gevonden</p><p className="mt-1 text-xs text-slate-400">Pas de zoekterm aan.</p></div> : <div className="max-h-[680px] divide-y divide-line overflow-y-auto">{filteredMembers.map((member) => <button key={member.id} type="button" onClick={() => chooseMember(member)} className={"flex w-full items-center gap-3 px-5 py-4 text-left transition " + (memberId === member.id ? "bg-brand-50" : "hover:bg-slate-50")}><span className="flex size-9 shrink-0 items-center justify-center rounded-full bg-brand-50 text-brand-700"><UsersRound className="size-4" /></span><span className="min-w-0 flex-1"><span className="block truncate text-xs font-bold text-ink">{member.name}</span><span className="mt-1 block truncate text-[10px] text-slate-400">{member.relationNumber ?? "Geen relatienummer"} · {member.team}</span></span><span className={"rounded-full px-2 py-1 text-[9px] font-bold " + (member.order?.paid ? "bg-emerald-50 text-success" : member.order ? "bg-amber-50 text-amber-700" : "bg-slate-100 text-slate-500")}>{member.order?.paid ? "Betaald" : member.order ? "Open" : "Geen order"}</span></button>)}</div>}
      </aside>

      {!selected ? (
        <section className="rounded-xl border border-brand-100 bg-brand-50 px-8 py-20 text-center"><ClipboardList className="mx-auto size-9 text-brand-400" /><h2 className="mt-5 text-base font-bold text-brand-900">Selecteer een lid</h2><p className="mx-auto mt-2 max-w-md text-xs leading-5 text-brand-700">Open een actief lid om de huidige seizoensbestelling te bekijken of veilig aan te maken.</p></section>
      ) : workspace.packageFeatureEnabled && !selectedHasLegacyOrder ? (
        <PackageOrderEditor
          member={selected}
          packageOrder={selectedPackageOrder}
          revisions={workspace.packageRevisions}
          activeSeason={workspace.activeSeason}
          canManage={canManagePackages}
          onChanged={(message) => {
            setNotice({ tone: "success", text: message });
            router.refresh();
          }}
        />
      ) : (
        <OrderEditor member={selected} articles={editableArticles} activeSeason={workspace.activeSeason} amount={amount} lines={lines} saving={saving} onAmount={setAmount} onVariant={updateLine} onQuantity={updateQuantity} onSubmit={submit} />
      )}
    </div>
  </div>;
}

function PackageOrderEditor({
  member,
  packageOrder,
  revisions,
  activeSeason,
  canManage,
  onChanged,
}: {
  member: Member;
  packageOrder: PackageOrder | null;
  revisions: PackageRevision[];
  activeSeason: Workspace["activeSeason"];
  canManage: boolean;
  onChanged: (message: string) => void;
}) {
  const defaultRevision = packageOrder?.packageRevisionId
    ?? revisions.find((revision) => revision.isDefault)?.revisionId
    ?? revisions[0]?.revisionId
    ?? "";
  const [revisionId, setRevisionId] = useState(defaultRevision);
  const [reason, setReason] = useState("");
  const [requestId, setRequestId] = useState(() => crypto.randomUUID());
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [changePreflight, setChangePreflight] =
    useState<PackageChangeResponse | null>(null);
  const currentPackage = revisions.find(
    (revision) => revision.revisionId === packageOrder?.packageRevisionId,
  );
  const editable = canManage
    && Boolean(activeSeason)
    && Boolean(revisionId)
    && Boolean(packageOrder);
  const targetsDifferentPackage = revisionId
    !== packageOrder?.packageRevisionId;
  const mutable = editable
    && targetsDifferentPackage
    && (!packageOrder?.orderId || packageOrder.canSwitchPackage);
  const requiresWorkflow = editable
    && targetsDifferentPackage
    && Boolean(packageOrder?.orderId)
    && !packageOrder?.canSwitchPackage;

  useEffect(() => {
    setRevisionId(defaultRevision);
    setReason("");
    setRequestId(crypto.randomUUID());
    setError(null);
    setChangePreflight(null);
  }, [defaultRevision, member.id]);

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (
      !packageOrder
      || (!mutable && !requiresWorkflow)
      || reason.trim().length < 4
    ) return;
    setSaving(true);
    setError(null);
    try {
      if (requiresWorkflow && packageOrder.orderId) {
        const response = await postMutation<PackageChangeResponse>(
          "/api/orders/package-change",
          {
            action: "preflight",
            orderId: packageOrder.orderId,
            targetPackageRevisionId: revisionId,
            reason,
            requestId,
          },
        );
        setChangePreflight(response);
        setRequestId(crypto.randomUUID());
      } else {
        await postMutation("/api/orders/package", {
          memberSeasonId: packageOrder.memberSeasonId,
          packageRevisionId: revisionId,
          revision: packageOrder.revision,
          reason,
          requestId,
        });
        onChanged(
          packageOrder.packageRevisionId
            ? "Pakketkeuze is gecontroleerd bijgewerkt."
            : "Pakketorder is aangemaakt.",
        );
      }
    } catch (mutationError) {
      setError(
        mutationError instanceof Error
          ? mutationError.message
          : "Het pakket kon niet worden verwerkt.",
      );
    } finally {
      setSaving(false);
    }
  }

  async function applyChange() {
    if (!changePreflight?.canApply) return;
    setSaving(true);
    setError(null);
    try {
      const response = await postMutation<PackageChangeResponse>(
        "/api/orders/package-change",
        {
          action: "apply",
          requestId: changePreflight.requestId,
          revision: changePreflight.revision,
          confirmation: changePreflight.requiresAllocationRelease
            ? "RELEASE_ALLOCATIONS_AND_SWITCH"
            : "SWITCH_PACKAGE",
        },
      );
      if (
        response.result?.paymentTransferred !== false
        || response.result?.refundCreated !== false
      ) {
        throw new Error("Onveilig financieel antwoord geweigerd.");
      }
      onChanged(
        "Pakket gewijzigd. Oude betalingen bleven aan hun historische snapshot gebonden.",
      );
    } catch (mutationError) {
      setError(
        mutationError instanceof Error
          ? mutationError.message
          : "De pakketwijziging kon niet worden uitgevoerd.",
      );
    } finally {
      setSaving(false);
    }
  }

  return (
    <form
      onSubmit={submit}
      className="overflow-hidden rounded-xl border border-line bg-white shadow-card"
    >
      <div className="flex flex-col gap-4 border-b border-line px-6 py-5 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <p className="text-[10px] font-bold uppercase tracking-[0.12em] text-brand-500">
            {activeSeason?.name ?? "Geen actief seizoen"}
          </p>
          <h2 className="mt-1 text-lg font-bold text-brand-900">
            {member.name}
          </h2>
          <p className="mt-1 text-xs text-slate-500">
            {member.relationNumber ?? "Geen relatienummer"} · {member.team}
          </p>
        </div>
        <span className="inline-flex h-8 items-center gap-2 self-start rounded-full bg-brand-50 px-3 text-[10px] font-bold text-brand-800">
          <PackageCheck className="size-3.5" />
          {currentPackage?.name ?? packageOrder?.packageName ?? "Nog geen pakket"}
        </span>
      </div>

      {!canManage && (
        <div className="border-b border-amber-200 bg-amber-50 px-6 py-4 text-xs leading-5 text-amber-800">
          Alleen een beheerder met MFA kan een pakket kiezen of wisselen.
        </div>
      )}
      {packageOrder?.orderId && !packageOrder.canSwitchPackage && (
        <div className="border-b border-brand-100 bg-brand-50 px-6 py-4 text-xs leading-5 text-brand-800">
          Dit pakket is betaald, gereserveerd of deels uitgegeven. Een gewone
          pakketwissel is daarom geblokkeerd. Maak hieronder eerst een
          geaudite preflight; een refund gebeurt nooit automatisch.
        </div>
      )}
      {error && (
        <div role="alert" className="border-b border-red-100 bg-red-50 px-6 py-4 text-xs text-danger">
          {error}
        </div>
      )}

      {changePreflight && (
        <div className="border-b border-line bg-slate-50 px-6 py-5 text-xs">
          <div className="grid gap-3 sm:grid-cols-3">
            <div>
              <p className="font-semibold text-slate-500">Prijsverschil</p>
              <p className="mt-1 font-bold text-brand-900">
                {(changePreflight.priceDeltaCents / 100).toLocaleString(
                  "nl-NL",
                  { style: "currency", currency: changePreflight.toCurrency },
                )}
              </p>
            </div>
            <div>
              <p className="font-semibold text-slate-500">Betaling</p>
              <p className="mt-1 font-bold text-brand-900">
                {changePreflight.requiresPaymentResolution
                  ? "Eerst extern oplossen"
                  : changePreflight.paidHistoryCount > 0
                    ? "Historie blijft gekoppeld"
                    : "Geen blokkade"}
              </p>
            </div>
            <div>
              <p className="font-semibold text-slate-500">Voorraad</p>
              <p className="mt-1 font-bold text-brand-900">
                {changePreflight.blockedByFulfilment
                  ? "Uitgifte blokkeert"
                  : changePreflight.requiresAllocationRelease
                    ? `${changePreflight.reservedAllocationCount} reservering(en) vrijgeven`
                    : "Geen blokkade"}
              </p>
            </div>
          </div>
          {changePreflight.requiresExternalRefund && (
            <p className="mt-4 rounded-lg border border-amber-200 bg-amber-50 p-3 leading-5 text-amber-900">
              Registreer of verifieer eerst de externe refund via de bestaande
              betaalcorrectie. Deze workflow maakt zelf geen refund en boekt
              geen betaling over.
            </p>
          )}
          {changePreflight.blockedByReconciliation && (
            <p className="mt-4 rounded-lg border border-red-200 bg-red-50 p-3 leading-5 text-danger">
              Een historische reservering is nog niet gereconcilieerd.
              Productie-uitvoering blijft geblokkeerd.
            </p>
          )}
          {changePreflight.canApply && (
            <div className="mt-4 flex justify-end">
              <button
                type="button"
                disabled={saving}
                onClick={() => void applyChange()}
                className="inline-flex h-10 items-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white disabled:opacity-50"
              >
                {saving
                  ? <Loader2 className="size-4 animate-spin" />
                  : <LockKeyhole className="size-4" />}
                {changePreflight.requiresAllocationRelease
                  ? "Reserveringen vrijgeven en wijzigen"
                  : "Gecontroleerd wijzigen"}
              </button>
            </div>
          )}
        </div>
      )}

      <fieldset disabled={!editable || saving} className="space-y-5 p-6">
        {revisions.length === 0 ? (
          <div className="rounded-lg border border-dashed border-line px-6 py-10 text-center">
            <PackageCheck className="mx-auto size-7 text-slate-300" />
            <p className="mt-3 text-xs font-semibold text-slate-600">
              Nog geen gepubliceerd pakket
            </p>
            <p className="mt-1 text-[10px] leading-4 text-slate-400">
              Voeg eerst zelf producten, maten en minimaal één gepubliceerd
              pakket toe onder Pakketten.
            </p>
          </div>
        ) : (
          <>
            <label className="block text-xs font-semibold text-ink">
              Pakket
              <select
                value={revisionId}
                onChange={(event) => {
                  setRevisionId(event.target.value);
                  setRequestId(crypto.randomUUID());
                  setChangePreflight(null);
                }}
                className={"mt-2 " + fieldClass}
              >
                {revisions.map((revision) => (
                  <option key={revision.revisionId} value={revision.revisionId}>
                    {revision.name} · {(revision.priceCents / 100).toLocaleString(
                      "nl-NL",
                      { style: "currency", currency: revision.currency },
                    )}
                    {revision.isDefault ? " · standaard" : ""}
                  </option>
                ))}
              </select>
            </label>
            <label className="block text-xs font-semibold text-ink">
              Reden
              <textarea
                value={reason}
                onChange={(event) => {
                  setReason(event.target.value);
                  setRequestId(crypto.randomUUID());
                  setChangePreflight(null);
                }}
                minLength={4}
                maxLength={480}
                required
                rows={3}
                placeholder="Bijvoorbeeld: pakket gekozen na controle met lid"
                className="mt-2 w-full rounded-lg border border-line bg-white px-3 py-2 text-sm outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100 disabled:bg-slate-50"
              />
            </label>
          </>
        )}
      </fieldset>

      <div className="flex items-center justify-end border-t border-line bg-slate-50/60 px-6 py-4">
        <button
          type="submit"
          disabled={
            (!mutable && !requiresWorkflow)
            || saving
            || reason.trim().length < 4
            || revisionId === packageOrder?.packageRevisionId
          }
          className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:opacity-50"
        >
          {saving ? <Loader2 className="size-4 animate-spin" /> : <CheckCircle2 className="size-4" />}
          {requiresWorkflow
            ? changePreflight
              ? "Opnieuw controleren"
              : "Wijziging controleren"
            : packageOrder?.packageRevisionId
              ? "Pakket wijzigen"
              : "Pakket kiezen"}
        </button>
      </div>
    </form>
  );
}

function PackageSizeChangesPanel({
  requests,
  onResolved,
}: {
  requests: PackageSizeChange[];
  onResolved: (message: string) => void;
}) {
  return (
    <section className="mt-6 rounded-xl border border-amber-200 bg-white shadow-card">
      <div className="border-b border-amber-100 bg-amber-50 px-5 py-4">
        <h2 className="text-sm font-bold text-amber-950">
          Maatwijzigingen na reservering
        </h2>
        <p className="mt-1 text-xs leading-5 text-amber-800">
          Beslis iedere wijziging expliciet. Goedkeuren geeft de oude
          reservering vrij en maakt een nieuwe naleverregel.
        </p>
      </div>
      <div className="divide-y divide-line">
        {requests.map((request) => (
          <PackageSizeChangeCard
            key={request.requestId}
            request={request}
            onResolved={onResolved}
          />
        ))}
      </div>
    </section>
  );
}

function PackageSizeChangeCard({
  request,
  onResolved,
}: {
  request: PackageSizeChange;
  onResolved: (message: string) => void;
}) {
  const initialVariant = request.requestedVariantId
    && request.variants.some(
      (variant) => variant.id === request.requestedVariantId,
    )
    ? request.requestedVariantId
    : "";
  const [variantId, setVariantId] = useState(initialVariant);
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState<"approve" | "reject" | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function decide(decision: "approve" | "reject") {
    if (reason.trim().length < 3 || (decision === "approve" && !variantId)) {
      return;
    }
    setSaving(decision);
    setError(null);
    try {
      await postMutation("/api/orders/package-size-change", {
        requestId: request.requestId,
        decision,
        approvedVariantId: decision === "approve" ? variantId : null,
        reason,
        revision: request.revision,
      });
      onResolved(
        decision === "approve"
          ? "Maatwijziging goedgekeurd; de nieuwe regel wacht op voorraad."
          : "Maatwijziging afgewezen; de bestaande reservering blijft gelden.",
      );
    } catch (mutationError) {
      setError(
        mutationError instanceof Error
          ? mutationError.message
          : "Het maatverzoek kon niet worden verwerkt.",
      );
    } finally {
      setSaving(null);
    }
  }

  return (
    <article className="grid gap-5 p-5 lg:grid-cols-[minmax(220px,0.8fr)_minmax(300px,1.2fr)]">
      <div>
        <p className="text-xs font-bold text-brand-900">{request.memberName}</p>
        <p className="mt-1 text-[10px] text-slate-400">
          {request.team ?? "Geen team"} · {request.articleName}
        </p>
        <dl className="mt-4 grid grid-cols-2 gap-3 text-xs">
          <div className="rounded-lg bg-slate-50 p-3">
            <dt className="text-[9px] font-bold uppercase tracking-wide text-slate-400">Gereserveerd</dt>
            <dd className="mt-1 font-semibold text-ink">{request.currentSize}</dd>
          </div>
          <div className="rounded-lg bg-amber-50 p-3">
            <dt className="text-[9px] font-bold uppercase tracking-wide text-amber-700">Gevraagd</dt>
            <dd className="mt-1 font-semibold text-amber-950">{requestedSizeLabel(request)}</dd>
          </div>
        </dl>
        {request.requestedMemberNote && (
          <p className="mt-3 rounded-lg border border-amber-100 bg-amber-50 px-3 py-2 text-xs leading-5 text-amber-900">
            {request.requestedMemberNote}
          </p>
        )}
      </div>
      <div className="space-y-3">
        <label className="block text-xs font-semibold text-ink">
          Concrete geldige maat bij goedkeuren
          <select
            value={variantId}
            onChange={(event) => setVariantId(event.target.value)}
            className={"mt-2 " + fieldClass}
          >
            <option value="">Selecteer een actieve maat</option>
            {request.variants.map((variant) => (
              <option key={variant.id} value={variant.id}>
                {variant.label}
              </option>
            ))}
          </select>
        </label>
        <label className="block text-xs font-semibold text-ink">
          Beslisreden
          <textarea
            value={reason}
            onChange={(event) => setReason(event.target.value)}
            minLength={3}
            maxLength={500}
            rows={2}
            className="mt-2 w-full rounded-lg border border-line bg-white px-3 py-2 text-sm outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100"
          />
        </label>
        {error && <p role="alert" className="text-xs text-danger">{error}</p>}
        <div className="flex flex-wrap gap-2">
          <button
            type="button"
            disabled={Boolean(saving) || reason.trim().length < 3 || !variantId}
            onClick={() => decide("approve")}
            className="inline-flex h-10 items-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white disabled:opacity-50"
          >
            {saving === "approve" && <Loader2 className="size-4 animate-spin" />}
            Goedkeuren
          </button>
          <button
            type="button"
            disabled={Boolean(saving) || reason.trim().length < 3}
            onClick={() => decide("reject")}
            className="inline-flex h-10 items-center gap-2 rounded-lg border border-line bg-white px-4 text-xs font-semibold text-slate-700 disabled:opacity-50"
          >
            {saving === "reject" && <Loader2 className="size-4 animate-spin" />}
            Afwijzen
          </button>
        </div>
      </div>
    </article>
  );
}

function OrderEditor({ member, articles, activeSeason, amount, lines, saving, onAmount, onVariant, onQuantity, onSubmit }: {
  member: Member;
  articles: Article[];
  activeSeason: Workspace["activeSeason"];
  amount: string;
  lines: DraftLine[];
  saving: boolean;
  onAmount: (value: string) => void;
  onVariant: (articleId: string, variantId: string) => void;
  onQuantity: (articleId: string, quantity: number) => void;
  onSubmit: (event: FormEvent) => void;
}) {
  const readOnly = Boolean(member.order?.paid);
  return <form onSubmit={onSubmit} className="overflow-hidden rounded-xl border border-line bg-white shadow-card">
    <div className="flex flex-col gap-4 border-b border-line px-6 py-5 sm:flex-row sm:items-start sm:justify-between"><div><p className="text-[10px] font-bold uppercase tracking-[0.12em] text-brand-500">{activeSeason?.name ?? "Geen actief seizoen"}</p><h2 className="mt-1 text-lg font-bold text-brand-900">{member.name}</h2><p className="mt-1 text-xs text-slate-500">{member.relationNumber ?? "Geen relatienummer"} · {member.team}</p></div><span className={"inline-flex h-8 items-center gap-2 self-start rounded-full px-3 text-[10px] font-bold " + (readOnly ? "bg-emerald-50 text-success" : "bg-amber-50 text-amber-700")}>{readOnly ? <LockKeyhole className="size-3.5" /> : <ClipboardList className="size-3.5" />}{readOnly ? "Betaald · alleen-lezen" : member.order ? "Open bestelling" : "Nieuwe bestelling"}</span></div>

    {readOnly && <div className="border-b border-brand-100 bg-brand-50 px-6 py-4 text-xs leading-5 text-brand-800">Deze bestelling is definitief betaald. Bedrag, maat en aantallen kunnen hier niet meer worden gewijzigd.</div>}

    <fieldset disabled={readOnly || !activeSeason || saving} className="p-6">
      <div className="max-w-sm"><label className="text-xs font-semibold text-ink">Exact verschuldigd bedrag<span className="mt-1 block text-[10px] font-normal leading-4 text-slate-400">Eén totaalbedrag voor deze bestelling; geen artikelprijzen of deelbedragen.</span><span className="relative mt-2 block"><span className="absolute left-3 top-1/2 -translate-y-1/2 text-sm font-semibold text-slate-500">€</span><input value={amount} onChange={(event) => onAmount(event.target.value)} required inputMode="decimal" aria-describedby="amount-help" className={fieldClass + " pl-8"} /></span></label><p id="amount-help" className="mt-2 text-[10px] text-slate-400">Gebruik maximaal twee decimalen, bijvoorbeeld 87,50.</p></div>

      <div className="mt-7 border-t border-line pt-6"><div className="flex items-end justify-between gap-4"><div><h3 className="text-sm font-bold text-brand-900">Artikelregels</h3><p className="mt-1 text-xs text-slate-500">Selecteer per artikel maximaal één variant en geef het aantal expliciet op.</p></div><span className="text-[10px] font-semibold text-slate-400">{lines.length} geselecteerd</span></div>
        {articles.length === 0 ? <div className="mt-5 rounded-lg border border-dashed border-line px-6 py-10 text-center"><Shirt className="mx-auto size-7 text-slate-300" /><p className="mt-3 text-xs font-semibold text-slate-500">Geen actieve artikelvarianten</p><p className="mt-1 text-[10px] text-slate-400">Activeer eerst artikelen en maten in de catalogus.</p></div> : <div className="mt-5 space-y-3">{articles.map((article) => {
          const line = lines.find((item) => item.articleId === article.id);
          const existingVariantId = member.order?.lines.find((item) => item.articleId === article.id)?.variantId;
          const options = article.variants.filter((variant) => variant.active || variant.id === existingVariantId);
          const existingStatus = member.order?.lines.find((item) => item.articleId === article.id)?.status;
          return <div key={article.id} className={"grid gap-3 rounded-xl border p-4 sm:grid-cols-[minmax(130px,0.7fr)_minmax(180px,1fr)_100px] sm:items-end " + (line ? "border-brand-100 bg-brand-50/40" : "border-line")}><div><p className="text-xs font-bold text-brand-900">{article.name}</p><p className="mt-1 text-[10px] text-slate-400">{article.code}{existingStatus ? " · " + lineStatusLabels[existingStatus] : ""}</p></div><label className="text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400">Maat<select value={line?.variantId ?? ""} onChange={(event) => onVariant(article.id, event.target.value)} className={"mt-2 " + fieldClass}><option value="">Niet opnemen</option>{options.map((variant) => <option key={variant.id} value={variant.id}>{variant.size}{variant.supplierCode ? " · " + variant.supplierCode : ""}{!variant.active ? " · inactief" : ""}</option>)}</select></label><label className="text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400">Aantal<input type="number" value={line?.quantity ?? 1} onChange={(event) => onQuantity(article.id, Number(event.target.value))} min={1} max={25} disabled={!line || readOnly} className={"mt-2 " + fieldClass} /></label></div>;
        })}</div>}
      </div>
    </fieldset>

    <div className="flex flex-col gap-3 border-t border-line bg-slate-50/60 px-6 py-4 sm:flex-row sm:items-center sm:justify-between"><p className="text-[10px] leading-4 text-slate-400">{readOnly ? "Historische en financiële gegevens blijven ongewijzigd." : "Opslaan valideert lid, seizoen, bedrag en varianten opnieuw op de server."}</p><button type="submit" disabled={readOnly || !activeSeason || saving || articles.length === 0} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:opacity-50">{saving ? <Loader2 className="size-4 animate-spin" /> : <CheckCircle2 className="size-4" />}{member.order ? "Bestelling opslaan" : "Bestelling aanmaken"}</button></div>
  </form>;
}
