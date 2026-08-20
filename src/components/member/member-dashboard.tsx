"use client";

import {
  AlertTriangle,
  ArrowRight,
  CalendarDays,
  CheckCircle2,
  CreditCard,
  Loader2,
  LockKeyhole,
  LogOut,
  PackageCheck,
  RefreshCw,
  UserRound,
} from "lucide-react";
import Image from "next/image";
import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { ArticleIcon } from "@/components/catalog/article-icon";
import type {
  ParentPackageMember,
  ParentPackageSizeSelection,
  ParentPackageWorkspace,
} from "@/lib/parent-package-contract";

type PackageItem = NonNullable<ParentPackageMember["order"]>["items"][number];
type SizeDraft = {
  kind: "" | "variant" | "other";
  variantId: string | null;
  note: string;
};
type MemberDrafts = Record<string, Record<string, SizeDraft>>;
type StringMap = Record<string, string>;

const amount = new Intl.NumberFormat("nl-NL", {
  style: "currency",
  currency: "EUR",
});
const date = new Intl.DateTimeFormat("nl-NL", {
  day: "numeric",
  month: "long",
  year: "numeric",
  timeZone: "Europe/Amsterdam",
});
const genderLabel = {
  male: "Jongen/man",
  female: "Meisje/vrouw",
  other: "Anders",
  unknown: "Niet geregistreerd",
};
const lineStatusLabel = {
  backorder: "Nalevering",
  ready_for_pickup: "Af te halen",
  picked_up: "Afgehaald",
  cancelled: "Geannuleerd",
};
const paymentLabel: Record<string, string> = {
  open: "Nog te betalen",
  pending: "Betaling wordt verwerkt",
  paid: "Betaald",
  failed: "Nog te betalen",
  canceled: "Nog te betalen",
  expired: "Nog te betalen",
  refunded: "Terugbetaald",
  duplicate_paid: "Betaling ontvangen",
};
const sourceLabel = {
  legacy: "Bestaande registratie",
  import: "Vooraf bekend",
  parent: "Door jou gekozen",
  staff: "Door beheer aangepast",
  order: "Bestaande bestelling",
};
const fieldClass =
  "h-11 w-full rounded-lg border border-line bg-white px-3 text-sm text-ink outline-none transition focus:border-brand-500 focus:ring-2 focus:ring-brand-100 disabled:cursor-not-allowed disabled:bg-slate-50 disabled:text-slate-400";

function fullName(member: ParentPackageMember) {
  return [member.firstName, member.insertion, member.lastName]
    .filter(Boolean)
    .join(" ");
}

export function initialSizeDraft(item: PackageItem): SizeDraft {
  if (item.requestedVariantId) {
    return { kind: "variant", variantId: item.requestedVariantId, note: "" };
  }
  if (item.requestedRawValue) {
    return {
      kind: "other",
      variantId: null,
      note: item.requestedMemberNote ?? "",
    };
  }
  if (item.selectionStatus === "conflict") {
    return {
      kind: "other",
      variantId: null,
      note:
        item.memberNote ??
        (item.rawValue ? `Geïmporteerde maat: ${item.rawValue}` : ""),
    };
  }
  if (item.selectedVariantId) {
    return {
      kind: "variant",
      variantId: item.selectedVariantId,
      note: "",
    };
  }
  return { kind: "", variantId: null, note: "" };
}

export function buildPackageSizeSelections(
  member: ParentPackageMember,
  drafts: Record<string, SizeDraft>,
): ParentPackageSizeSelection[] | null {
  if (!member.order || member.order.items.length === 0) return null;
  const selections: ParentPackageSizeSelection[] = [];
  for (const item of member.order.items) {
    const draft = drafts[item.articleId] ?? initialSizeDraft(item);
    if (draft.kind === "variant" && draft.variantId) {
      selections.push({
        articleId: item.articleId,
        kind: "variant",
        variantId: draft.variantId,
        note: null,
      });
      continue;
    }
    if (draft.kind === "other" && draft.note.trim()) {
      selections.push({
        articleId: item.articleId,
        kind: "other",
        variantId: null,
        note: draft.note.trim(),
      });
      continue;
    }
    return null;
  }
  return selections;
}

function paymentBadge(status: string | null) {
  if (status === "paid" || status === "duplicate_paid") {
    return "bg-emerald-50 text-success";
  }
  if (status === "pending") return "bg-brand-50 text-brand-700";
  if (status === "refunded") return "bg-slate-100 text-slate-600";
  return "bg-amber-50 text-warning";
}

export function canStartPayment(member: ParentPackageMember) {
  const order = member.order;
  return Boolean(
    order &&
    !order.legacy &&
    !["paid", "pending", "refunded", "duplicate_paid"].includes(
      order.paymentStatus ?? "open",
    ) &&
    order.sizesConfirmed &&
    order.items.length > 0 &&
    order.items.every(
      (item) =>
        item.selectedVariantId &&
        !["conflict", "change_requested"].includes(item.selectionStatus ?? "") &&
        item.variants.some(
          (variant) => variant.id === item.selectedVariantId && variant.active,
        ),
    ),
  );
}

export function packageSizeAction(member: ParentPackageMember) {
  const order = member.order;
  if (
    !order ||
    order.legacy ||
    !order.items.some(
      (item) => !item.issued && item.selectionStatus !== "locked",
    )
  ) {
    return null;
  }
  if (order.items.some((item) => !item.selectedVariantId)) {
    return "fill" as const;
  }
  return "review" as const;
}

function itemStatus(item: PackageItem) {
  if (item.issued || item.selectionStatus === "locked") {
    return {
      label: "Uitgegeven · vergrendeld",
      style: "bg-slate-100 text-slate-600",
    };
  }
  if (item.selectionStatus === "change_requested") {
    return {
      label: "Wijziging wacht op beheer",
      style: "bg-amber-50 text-warning",
    };
  }
  if (item.selectionStatus === "imported_unconfirmed") {
    return { label: "Nog controleren", style: "bg-brand-50 text-brand-700" };
  }
  if (item.selectionStatus === "conflict") {
    return { label: "Maat vraagt aandacht", style: "bg-red-50 text-danger" };
  }
  if (item.selectionStatus === "confirmed") {
    return { label: "Bevestigd", style: "bg-emerald-50 text-success" };
  }
  return { label: "Nog invullen", style: "bg-slate-100 text-slate-600" };
}

function QrPanel({ member }: { member: ParentPackageMember }) {
  const order = member.order;
  if (order?.qrDataUrl) {
    return (
      <div className="flex flex-col items-center justify-center rounded-xl border border-brand-100 bg-white p-3 text-center">
        <Image
          src={order.qrDataUrl}
          alt={`QR voor ${fullName(member)}`}
          width={144}
          height={144}
          unoptimized
          className="size-28"
        />
        <p className="mt-2 text-[10px] font-semibold text-brand-700">
          Toon bij uitgifte
        </p>
      </div>
    );
  }
  return (
    <div className="flex flex-col items-center justify-center rounded-xl border border-dashed border-line bg-canvas p-4 text-center">
      <LockKeyhole className="size-5 text-slate-400" aria-hidden="true" />
      <p className="mt-2 text-[10px] font-semibold text-slate-500">
        QR vergrendeld
      </p>
      <p className="mt-1 max-w-32 text-[9px] leading-4 text-slate-400">
        {!["paid", "duplicate_paid"].includes(order?.paymentStatus ?? "")
          ? "Beschikbaar na betaling en wanneer één of meerdere producten af te halen zijn"
          : "Wordt actief zodra minimaal één product af te halen is"}
      </p>
    </div>
  );
}

function PackageChoice({
  member,
  selectedRevisionId,
  busy,
  onSelect,
  onSubmit,
}: {
  member: ParentPackageMember;
  selectedRevisionId: string;
  busy: boolean;
  onSelect: (revisionId: string) => void;
  onSubmit: () => void;
}) {
  if (member.availablePackages.length === 0) {
    return (
      <div className="rounded-xl border border-dashed border-line bg-slate-50 p-5 text-center">
        <PackageCheck className="mx-auto size-6 text-slate-300" />
        <p className="mt-3 text-xs font-semibold text-slate-600">
          Nog geen kledingpakket beschikbaar
        </p>
        <p className="mt-1 text-[11px] text-slate-400">
          De beheerder stelt eerst de pakketinhoud en prijs samen.
        </p>
      </div>
    );
  }

  return (
    <fieldset disabled={busy}>
      <legend className="text-sm font-bold text-brand-900">
        Kies het kledingpakket
      </legend>
      <p className="mt-1 text-xs leading-5 text-slate-500">
        Bekijk de volledige inhoud en kies daarna één pakket voor dit seizoen.
      </p>
      <div className="mt-4 grid gap-3 sm:grid-cols-2">
        {member.availablePackages.map((option) => {
          const selected = selectedRevisionId === option.revisionId;
          return (
            <label
              key={option.revisionId}
              className={`cursor-pointer rounded-xl border p-4 transition ${
                selected
                  ? "border-brand-500 bg-brand-50/50 ring-2 ring-brand-100"
                  : "border-line bg-white hover:border-brand-200"
              }`}
            >
              <span className="flex items-start gap-3">
                <input
                  type="radio"
                  name={`package-${member.memberSeasonId}`}
                  value={option.revisionId}
                  checked={selected}
                  onChange={() => onSelect(option.revisionId)}
                  className="mt-1 size-4 accent-brand-700"
                />
                <span className="min-w-0 flex-1">
                  <span className="flex items-center justify-between gap-3">
                    <span className="text-sm font-bold text-brand-900">
                      {option.name}
                    </span>
                    <span className="text-xs font-bold text-brand-700">
                      {amount.format(option.priceCents / 100)}
                    </span>
                  </span>
                  {option.description && (
                    <span className="mt-1 block text-[11px] leading-4 text-slate-500">
                      {option.description}
                    </span>
                  )}
                  <span className="mt-3 block space-y-1 border-t border-line pt-3">
                    {option.items.map((item) => (
                      <span
                        key={item.articleId}
                        className="flex justify-between gap-3 text-[10px] text-slate-500"
                      >
                        <span>{item.name}</span>
                        <span>× {item.quantity}</span>
                      </span>
                    ))}
                  </span>
                </span>
              </span>
            </label>
          );
        })}
      </div>
      <button
        type="button"
        onClick={onSubmit}
        disabled={!selectedRevisionId || busy}
        className="mt-4 inline-flex h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:opacity-50 sm:w-auto"
      >
        {busy ? (
          <Loader2 className="size-4 animate-spin" />
        ) : (
          <PackageCheck className="size-4" />
        )}
        Pakket kiezen
      </button>
    </fieldset>
  );
}

function SizeItem({
  item,
  draft,
  disabled,
  onChange,
}: {
  item: PackageItem;
  draft: SizeDraft;
  disabled: boolean;
  onChange: (draft: SizeDraft) => void;
}) {
  const status = itemStatus(item);
  const selectValue =
    draft.kind === "variant"
      ? (draft.variantId ?? "")
      : draft.kind === "other"
        ? "__other__"
        : "";
  return (
    <div className="rounded-xl border border-line bg-white p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p className="flex items-center gap-2 text-sm font-bold text-brand-900">
            <ArticleIcon
              type={item.iconType}
              className="size-4 text-brand-500"
            />
            {item.name}
            {item.quantity > 1 && (
              <span className="text-xs text-slate-400">× {item.quantity}</span>
            )}
          </p>
          <p className="mt-1 text-[10px] text-slate-400">
            {item.code}
            {item.selectionSource
              ? ` · ${sourceLabel[item.selectionSource]}`
              : ""}
          </p>
        </div>
        <span
          className={`rounded-full px-2.5 py-1 text-[10px] font-semibold ${status.style}`}
        >
          {status.label}
        </span>
      </div>

      {item.rawValue && item.selectionStatus === "conflict" && (
        <div className="mt-3 rounded-lg border border-red-100 bg-red-50 px-3 py-2 text-[11px] text-red-800">
          Niet herkende bronwaarde: <strong>{item.rawValue}</strong>. Er is geen
          fictieve voorraadmaat aangemaakt.
        </div>
      )}
      {item.selectionStatus === "change_requested" && (
        <div className="mt-3 rounded-lg border border-amber-100 bg-amber-50 px-3 py-2 text-[11px] leading-4 text-amber-800">
          De huidige reservering blijft staan totdat de kledingcommissie jouw
          verzoek goedkeurt of afwijst.
        </div>
      )}

      <label className="mt-4 block text-[10px] font-bold uppercase tracking-[0.08em] text-slate-500">
        Maat
        <select
          value={selectValue}
          disabled={disabled}
          onChange={(event) => {
            if (event.target.value === "__other__") {
              onChange({ kind: "other", variantId: null, note: draft.note });
            } else if (event.target.value) {
              onChange({
                kind: "variant",
                variantId: event.target.value,
                note: "",
              });
            } else {
              onChange({ kind: "", variantId: null, note: "" });
            }
          }}
          className={`mt-2 ${fieldClass}`}
        >
          <option value="">Kies een maat</option>
          {item.variants.map((variant) => (
            <option key={variant.id} value={variant.id}>
              {variant.label}
              {variant.active ? "" : " · niet meer actief"}
            </option>
          ))}
          <option value="__other__">Anders…</option>
        </select>
      </label>
      {draft.kind === "other" && (
        <label className="mt-3 block text-[10px] font-bold uppercase tracking-[0.08em] text-slate-500">
          Verplichte toelichting
          <textarea
            value={draft.note}
            disabled={disabled}
            onChange={(event) =>
              onChange({ ...draft, note: event.target.value })
            }
            minLength={1}
            maxLength={500}
            rows={3}
            className="mt-2 w-full resize-y rounded-lg border border-line bg-white px-3 py-2 text-sm font-normal normal-case tracking-normal text-ink outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100 disabled:bg-slate-50"
            placeholder="Beschrijf welke maat of pasvorm nodig is"
          />
        </label>
      )}
      {item.lineStatus && (
        <p className="mt-3 text-[10px] font-semibold text-slate-500">
          Logistiek: {lineStatusLabel[item.lineStatus]}
        </p>
      )}
    </div>
  );
}

export function MemberDashboard() {
  const [workspace, setWorkspace] = useState<ParentPackageWorkspace>({
    enabled: false,
    members: [],
  });
  const [drafts, setDrafts] = useState<MemberDrafts>({});
  const [packageChoices, setPackageChoices] = useState<StringMap>({});
  const [selectionRequestIds, setSelectionRequestIds] = useState<StringMap>({});
  const [sizeRequestIds, setSizeRequestIds] = useState<StringMap>({});
  const [busyMember, setBusyMember] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadedSuccessfully, setLoadedSuccessfully] = useState(false);
  const [unauthorized, setUnauthorized] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  async function load() {
    setLoading(true);
    setError(null);
    try {
      const response = await fetch("/api/parent/members", {
        cache: "no-store",
        credentials: "same-origin",
      });
      if (response.status === 401) {
        setUnauthorized(true);
        return;
      }
      if (!response.ok) throw new Error();
      const payload = (await response.json()) as ParentPackageWorkspace;
      setWorkspace(payload);
      setLoadedSuccessfully(true);
      setDrafts(
        Object.fromEntries(
          payload.members.map((member) => [
            member.memberSeasonId,
            Object.fromEntries(
              (member.order?.items ?? []).map((item) => [
                item.articleId,
                initialSizeDraft(item),
              ]),
            ),
          ]),
        ),
      );
      setPackageChoices(
        Object.fromEntries(
          payload.members.map((member) => [
            member.memberSeasonId,
            member.order?.packageRevisionId ??
              member.availablePackages.find((option) => option.isDefault)
                ?.revisionId ??
              member.availablePackages[0]?.revisionId ??
              "",
          ]),
        ),
      );
      setUnauthorized(false);
    } catch {
      setError("De leden konden niet worden geladen.");
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void load();
  }, []);

  async function logout() {
    await fetch("/api/parent-auth/logout", {
      method: "POST",
      headers: { "X-Duindorp-CSRF": "same-origin" },
    });
    window.location.assign("/login");
  }

  function choosePackage(memberSeasonId: string, revisionId: string) {
    setPackageChoices((current) => ({
      ...current,
      [memberSeasonId]: revisionId,
    }));
    setSelectionRequestIds((current) => {
      const next = { ...current };
      delete next[memberSeasonId];
      return next;
    });
  }

  async function submitPackage(member: ParentPackageMember) {
    const packageRevisionId = packageChoices[member.memberSeasonId];
    if (!packageRevisionId) return;
    const requestId =
      selectionRequestIds[member.memberSeasonId] ?? crypto.randomUUID();
    setSelectionRequestIds((current) => ({
      ...current,
      [member.memberSeasonId]: requestId,
    }));
    setBusyMember(member.memberSeasonId);
    setNotice(null);
    try {
      const response = await fetch("/api/parent/packages/select", {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          "X-Duindorp-CSRF": "same-origin",
        },
        body: JSON.stringify({
          memberSeasonId: member.memberSeasonId,
          packageRevisionId,
          revision: member.revision,
          requestId,
        }),
      });
      const payload = (await response.json()) as { error?: string };
      if (!response.ok) {
        if (response.status < 500) {
          setSelectionRequestIds((current) => {
            const next = { ...current };
            delete next[member.memberSeasonId];
            return next;
          });
        }
        throw new Error(payload.error ?? "Het pakket kon niet worden gekozen.");
      }
      setSelectionRequestIds((current) => {
        const next = { ...current };
        delete next[member.memberSeasonId];
        return next;
      });
      setNotice("Het kledingpakket is opgeslagen. Controleer nu alle maten.");
      await load();
    } catch (requestError) {
      setError(
        requestError instanceof Error
          ? requestError.message
          : "Het pakket kon niet worden gekozen.",
      );
    } finally {
      setBusyMember(null);
    }
  }

  function updateSizeDraft(
    memberSeasonId: string,
    articleId: string,
    draft: SizeDraft,
  ) {
    setDrafts((current) => ({
      ...current,
      [memberSeasonId]: {
        ...current[memberSeasonId],
        [articleId]: draft,
      },
    }));
    setSizeRequestIds((current) => {
      const next = { ...current };
      delete next[memberSeasonId];
      return next;
    });
  }

  async function confirmSizes(member: ParentPackageMember) {
    const selections = buildPackageSizeSelections(
      member,
      drafts[member.memberSeasonId] ?? {},
    );
    if (!selections) {
      setError("Kies voor ieder product een maat of licht toe.");
      return;
    }
    const requestId =
      sizeRequestIds[member.memberSeasonId] ?? crypto.randomUUID();
    setSizeRequestIds((current) => ({
      ...current,
      [member.memberSeasonId]: requestId,
    }));
    setBusyMember(member.memberSeasonId);
    setNotice(null);
    setError(null);
    try {
      const response = await fetch("/api/parent/packages/sizes", {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          "X-Duindorp-CSRF": "same-origin",
        },
        body: JSON.stringify({
          memberSeasonId: member.memberSeasonId,
          revision: member.revision,
          requestId,
          selections,
        }),
      });
      const payload = (await response.json()) as {
        error?: string;
        changeRequestCount?: number;
        conflictCount?: number;
      };
      if (!response.ok) {
        if (response.status < 500) {
          setSizeRequestIds((current) => {
            const next = { ...current };
            delete next[member.memberSeasonId];
            return next;
          });
        }
        throw new Error(
          payload.error ?? "De maten konden niet worden bevestigd.",
        );
      }
      setSizeRequestIds((current) => {
        const next = { ...current };
        delete next[member.memberSeasonId];
        return next;
      });
      setNotice(
        (payload.changeRequestCount ?? 0) > 0
          ? "De maten zijn bevestigd. De kledingcommissie kan alleen nog maten wijzigen."
          : (payload.conflictCount ?? 0) > 0
            ? "De maten zijn bevestigd."
            : "Alle maten zijn bevestigd.",
      );
      await load();
    } catch (requestError) {
      setError(
        requestError instanceof Error
          ? requestError.message
          : "De maten konden niet worden bevestigd.",
      );
    } finally {
      setBusyMember(null);
    }
  }

  const memberCountLabel = useMemo(
    () =>
      workspace.members.length === 1
        ? "1 lid"
        : `${workspace.members.length} leden`,
    [workspace.members.length],
  );

  if (loading) {
    return (
      <div className="mx-auto max-w-[980px] animate-pulse">
        <div className="h-8 w-56 rounded bg-slate-200" />
        <div className="mt-8 h-96 rounded-2xl bg-white" />
      </div>
    );
  }

  if (unauthorized) {
    return (
      <div className="mx-auto max-w-[560px] text-center">
        <div className="mx-auto flex size-14 items-center justify-center rounded-2xl bg-brand-700 text-white">
          <LockKeyhole className="size-6" />
        </div>
        <h1 className="mt-6 text-3xl font-bold tracking-tight text-brand-900">
          Log in om je tenue te bekijken
        </h1>
        <p className="mt-3 text-sm leading-6 text-slate-500">
          Je ouderaccount is niet actief in deze browser.
        </p>
        <Link
          href="/login"
          className="mt-7 inline-flex items-center gap-2 rounded-lg bg-brand-700 px-4 py-2.5 text-xs font-semibold text-white hover:bg-brand-900"
        >
          Naar ouderlogin <ArrowRight className="size-4" />
        </Link>
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-[980px]">
      <div className="flex flex-col justify-between gap-4 sm:flex-row sm:items-end">
        <div>
          <p className="text-xs font-bold uppercase tracking-[0.14em] text-brand-500">
            Mijn Duindorp SV tenue
          </p>
          <h1 className="mt-2 text-3xl font-bold tracking-tight text-brand-900">
            Jouw kledingpakketten
          </h1>
          <p className="mt-2 text-sm text-slate-500">
            {loadedSuccessfully
              ? memberCountLabel
              : "Leden konden niet worden geladen"}
            . Je oude gegevens worden per seizoen opnieuw gebruikt.
          </p>
        </div>
        <div className="flex gap-2">
          <button
            onClick={() => void load()}
            className="inline-flex items-center justify-center gap-2 rounded-lg border border-line bg-white px-3.5 py-2.5 text-xs font-semibold text-slate-600 hover:border-brand-500"
          >
            <RefreshCw className="size-3.5" /> Vernieuwen
          </button>
          <button
            onClick={() => void logout()}
            className="inline-flex items-center justify-center gap-2 rounded-lg border border-line bg-white px-3.5 py-2.5 text-xs font-semibold text-slate-600 hover:border-brand-500"
          >
            <LogOut className="size-3.5" /> Uitloggen
          </button>
        </div>
      </div>

      {notice && (
        <div
          role="status"
          className="mt-5 rounded-xl border border-emerald-100 bg-emerald-50 px-4 py-3 text-xs font-semibold text-emerald-800"
        >
          {notice}
        </div>
      )}
      {error && (
        <div
          role="alert"
          className="mt-5 flex items-start gap-3 rounded-xl border border-red-100 bg-red-50 px-4 py-3 text-xs text-red-800"
        >
          <AlertTriangle className="mt-0.5 size-4 shrink-0" />
          <span className="flex-1">{error}</span>
          <button
            onClick={() => setError(null)}
            className="font-bold underline"
          >
            Sluiten
          </button>
        </div>
      )}

      {!loadedSuccessfully ? (
        <div className="mt-8 rounded-2xl border border-red-100 bg-white p-8 text-center shadow-card">
          <AlertTriangle className="mx-auto size-7 text-danger" />
          <h2 className="mt-4 text-base font-bold text-brand-900">
            Portaalgegevens tijdelijk niet beschikbaar
          </h2>
          <p className="mx-auto mt-2 max-w-lg text-sm leading-6 text-slate-500">
            Je bestaande toegang en koppelingen zijn niet verwijderd. Probeer de
            gegevens opnieuw te laden.
          </p>
          <button
            type="button"
            onClick={() => void load()}
            className="mt-5 inline-flex h-11 items-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900"
          >
            <RefreshCw className="size-4" /> Opnieuw proberen
          </button>
        </div>
      ) : workspace.members.length === 0 ? (
        <div className="mt-8 rounded-2xl border border-line bg-white p-8 text-center shadow-card">
          <UserRound className="mx-auto size-7 text-brand-500" />
          <h2 className="mt-4 text-base font-bold text-brand-900">
            Nog geen toegang geactiveerd
          </h2>
          <p className="mt-2 text-sm text-slate-500">
            Alleen een beheerder kan portaaltoegang voor een lid en seizoen
            activeren. Neem contact op met de kledingcommissie via
            kleding@duindorpsv.nl!
          </p>
        </div>
      ) : (
        <div className="mt-8 space-y-6">
          {workspace.members.map((member) => {
            const order = member.order;
            const busy = busyMember === member.memberSeasonId;
            const memberDraft = drafts[member.memberSeasonId] ?? {};
            const selections = buildPackageSizeSelections(member, memberDraft);
            const hasEditableItems = Boolean(
              order?.items.some(
                (item) => !item.issued && item.selectionStatus !== "locked",
              ),
            );
            return (
              <article
                key={member.memberSeasonId}
                className="overflow-hidden rounded-2xl border border-line bg-white shadow-card"
              >
                <header className="border-b border-line px-5 py-5 sm:px-6">
                  <div className="flex flex-wrap items-start justify-between gap-4">
                    <div className="flex min-w-0 items-center gap-3">
                      <div className="flex size-11 shrink-0 items-center justify-center rounded-full bg-brand-50 text-sm font-bold text-brand-700">
                        {member.firstName.slice(0, 1)}
                        {member.lastName.slice(0, 1)}
                      </div>
                      <div className="min-w-0">
                        <h2 className="truncate text-base font-bold text-brand-900">
                          {fullName(member)}
                        </h2>
                        <p className="mt-1 text-xs text-slate-500">
                          {member.team ?? "Team nog niet vastgesteld"} ·{" "}
                          {member.relationNumber ?? "Geen relatienummer"}
                        </p>
                      </div>
                    </div>
                    <span
                      className={`rounded-full px-2.5 py-1 text-[10px] font-semibold ${paymentBadge(order?.paymentStatus ?? null)}`}
                    >
                      {order
                        ? (paymentLabel[order.paymentStatus ?? "open"] ??
                          "Nog te betalen")
                        : "Nog geen pakket"}
                    </span>
                  </div>
                  <div className="mt-4 flex flex-wrap gap-x-4 gap-y-2 text-[11px] text-slate-500">
                    <span className="inline-flex items-center gap-1.5">
                      <UserRound className="size-3.5 text-brand-500" />
                      {genderLabel[member.gender]}
                    </span>
                    {member.dateOfBirth && (
                      <span className="inline-flex items-center gap-1.5">
                        <CalendarDays className="size-3.5 text-brand-500" />
                        {date.format(
                          new Date(`${member.dateOfBirth}T12:00:00+02:00`),
                        )}
                      </span>
                    )}
                    <span>{member.seasonName}</span>
                  </div>
                </header>

                <div className="p-5 sm:p-6">
                  {!order && workspace.enabled && (
                    <PackageChoice
                      member={member}
                      selectedRevisionId={
                        packageChoices[member.memberSeasonId] ?? ""
                      }
                      busy={busy}
                      onSelect={(revisionId) =>
                        choosePackage(member.memberSeasonId, revisionId)
                      }
                      onSubmit={() => void submitPackage(member)}
                    />
                  )}

                  {!order && !workspace.enabled && (
                    <div className="rounded-xl border border-dashed border-line bg-slate-50 p-5 text-center text-xs text-slate-500">
                      De pakketmodule is tijdelijk veilig gepauzeerd.
                    </div>
                  )}

                  {order?.legacy && (
                    <div className="rounded-xl border border-amber-100 bg-amber-50 p-4 text-xs leading-5 text-amber-900">
                      Dit is een oude bestelling.
                    </div>
                  )}

                  {order && !order.legacy && (
                    <>
                      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
                        <div>
                          <p className="text-[10px] font-bold uppercase tracking-[0.1em] text-brand-500">
                            Gekozen pakket
                          </p>
                          <h3 className="mt-1 text-xl font-bold text-brand-900">
                            {order.packageName}
                          </h3>
                          {order.packageDescription && (
                            <p className="mt-1 max-w-xl text-xs leading-5 text-slate-500">
                              {order.packageDescription}
                            </p>
                          )}
                        </div>
                        <p className="text-lg font-bold text-brand-900">
                          {amount.format(
                            (order.packagePriceCents ?? order.amountDueCents) /
                              100,
                          )}
                        </p>
                      </div>

                      {order.canSwitchPackage &&
                        member.availablePackages.length > 1 && (
                          <details className="mt-5 rounded-xl border border-line bg-slate-50 p-4">
                            <summary className="cursor-pointer text-xs font-bold text-brand-800">
                              Ander pakket kiezen
                            </summary>
                            <div className="mt-4">
                              <PackageChoice
                                member={member}
                                selectedRevisionId={
                                  packageChoices[member.memberSeasonId] ??
                                  order.packageRevisionId ??
                                  ""
                                }
                                busy={busy}
                                onSelect={(revisionId) =>
                                  choosePackage(
                                    member.memberSeasonId,
                                    revisionId,
                                  )
                                }
                                onSubmit={() => void submitPackage(member)}
                              />
                            </div>
                          </details>
                        )}

                      {packageSizeAction(member) && (
                        <a
                          href={`#maten-${member.memberSeasonId}`}
                          className="mt-6 flex items-start gap-3 rounded-xl border border-amber-200 bg-amber-50 p-4 text-amber-950 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2"
                        >
                          <AlertTriangle className="mt-0.5 size-4 shrink-0" />
                          <span>
                            <strong className="block text-xs">
                              {order.sizesConfirmed
                                ? "Maten aanpassen en opnieuw bevestigen"
                                : packageSizeAction(member) === "fill"
                                  ? "Het is verplicht om de maten in te vullen."
                                  : "Maten controleren en bevestigen"}
                            </strong>
                            <span className="mt-1 block text-xs leading-5">
                              {order.sizesConfirmed
                                ? "Vóór reservering kun je een correctie doorgeven en het pakket opnieuw bevestigen."
                                : packageSizeAction(member) === "fill"
                                  ? "Kies voor ieder product een geldige maat en bevestig daarna het volledige pakket."
                                  : "Controleer alle vooraf ingevulde maten en bevestig daarna het volledige pakket."}
                            </span>
                          </span>
                        </a>
                      )}

                      <div
                        id={`maten-${member.memberSeasonId}`}
                        className="mt-7 scroll-mt-6 border-t border-line pt-6"
                      >
                        <div className="flex flex-wrap items-end justify-between gap-3">
                          <div>
                            <h3 className="text-sm font-bold text-brand-900">
                              Maten per product
                            </h3>
                            <p className="mt-1 text-xs leading-5 text-slate-500">
                              Controleer alle vooraf ingevulde maten en bevestig
                              het pakket in één keer.
                            </p>
                          </div>
                          {order.sizesConfirmed && (
                            <span className="inline-flex items-center gap-1.5 text-[11px] font-semibold text-success">
                              <CheckCircle2 className="size-4" />
                              Maten bevestigd
                            </span>
                          )}
                        </div>
                        <div className="mt-4 grid gap-3 md:grid-cols-2">
                          {order.items.map((item) => (
                            <SizeItem
                              key={item.snapshotItemId}
                              item={item}
                              draft={
                                memberDraft[item.articleId] ??
                                initialSizeDraft(item)
                              }
                              disabled={
                                busy ||
                                item.issued ||
                                item.selectionStatus === "locked"
                              }
                              onChange={(draft) =>
                                updateSizeDraft(
                                  member.memberSeasonId,
                                  item.articleId,
                                  draft,
                                )
                              }
                            />
                          ))}
                        </div>
                        {hasEditableItems && (
                          <div className="mt-4 flex flex-col items-start justify-between gap-3 rounded-xl bg-slate-50 px-4 py-4 sm:flex-row sm:items-center">
                            <p className="text-[10px] leading-4 text-slate-500">
                              Na reservering kan alleen de kledingcommissie de
                              maten nog wijzigen.
                            </p>
                            <button
                              type="button"
                              onClick={() => void confirmSizes(member)}
                              disabled={!selections || busy}
                              className="inline-flex h-11 w-full shrink-0 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:opacity-50 sm:w-auto"
                            >
                              {busy ? (
                                <Loader2 className="size-4 animate-spin" />
                              ) : (
                                <CheckCircle2 className="size-4" />
                              )}
                              Alle maten bevestigen
                            </button>
                          </div>
                        )}
                      </div>
                    </>
                  )}

                  {order && (
                    <div className="mt-6 grid gap-4 border-t border-line pt-5 sm:grid-cols-[1fr_150px]">
                      <div>
                        {order.articleLines.length > 0 && (
                          <>
                            <p className="text-[10px] font-bold uppercase tracking-[0.1em] text-slate-400">
                              Levering en uitgifte
                            </p>
                            <div className="mt-3 space-y-2">
                              {order.articleLines.map((line) => (
                                <div
                                  key={line.id}
                                  className="flex items-center justify-between gap-3 rounded-lg bg-slate-50 px-3 py-2"
                                >
                                  <span className="text-xs font-medium text-ink">
                                    {line.article} · {line.size}
                                    {line.quantity > 1
                                      ? ` × ${line.quantity}`
                                      : ""}
                                  </span>
                                  <span className="text-[10px] font-semibold text-slate-500">
                                    {lineStatusLabel[line.status]}
                                  </span>
                                </div>
                              ))}
                            </div>
                          </>
                        )}
                        <div className="mt-5 flex flex-wrap items-center gap-3">
                          <div className="mr-auto">
                            <p className="text-[10px] text-slate-400">
                              Verschuldigd bedrag
                            </p>
                            <p className="mt-1 text-sm font-bold text-ink">
                              {amount.format(order.amountDueCents / 100)}
                            </p>
                            {canStartPayment(member) && (
                              <p className="mt-1 max-w-sm text-[10px] leading-4 text-slate-500">
                                Je kunt direct betalen. De QR wordt pas actief
                                wanneer één of meerdere producten af te halen
                                zijn.
                              </p>
                            )}
                          </div>
                          {["paid", "duplicate_paid"].includes(
                            order.paymentStatus ?? "",
                          ) && (
                            <span className="inline-flex items-center gap-1.5 text-[11px] font-semibold text-success">
                              <CheckCircle2 className="size-4" />
                              Betaling ontvangen
                            </span>
                          )}
                          {order.paymentStatus === "pending" && (
                            <span className="inline-flex items-center gap-1.5 text-[11px] font-semibold text-brand-700">
                              <Loader2 className="size-4 animate-spin" />
                              Wordt verwerkt
                            </span>
                          )}
                          {canStartPayment(member) && (
                            <Link
                              href={`/betaling/${order.id}`}
                              className="inline-flex h-11 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2"
                            >
                              <CreditCard className="size-4" />
                              Betaal {amount.format(order.amountDueCents / 100)}
                            </Link>
                          )}
                          {!canStartPayment(member) &&
                            !["paid", "pending", "refunded", "duplicate_paid"].includes(order.paymentStatus ?? "") && (
                              <a href={`#maten-${member.memberSeasonId}`} className="inline-flex h-11 items-center justify-center rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2">
                                {packageSizeAction(member) === "review"
                                  ? "Maten controleren"
                                  : "Maten invullen"}
                              </a>
                            )}
                          {["paid", "duplicate_paid"].includes(order.paymentStatus ?? "") && !order.sizesConfirmed && (
                            <p className="w-full text-xs font-semibold text-amber-800">
                              Je kledingpakket is betaald. Controleer en bevestig
                              eerst alle maten.
                            </p>
                          )}
                        </div>
                      </div>
                      <QrPanel member={member} />
                    </div>
                  )}
                </div>
              </article>
            );
          })}
        </div>
      )}
    </div>
  );
}
