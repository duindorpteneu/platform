"use client";

import {
  AlertTriangle,
  Archive,
  CheckCircle2,
  CopyPlus,
  Crown,
  Edit3,
  History,
  Loader2,
  Package,
  Plus,
  Save,
  Send,
  Shirt,
} from "lucide-react";
import Link from "next/link";
import { FormEvent, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import {
  formatPackagePrice,
  packageSeasonRequiresExplicitDefault,
  parsePackagePriceToCents,
  type PackageWorkspaceData,
} from "@/lib/package-contract";

type Template = PackageWorkspaceData["templates"][number];
type Revision = Template["revisions"][number];
type Notice = { tone: "error" | "success"; text: string } | null;
type MutationResponse = {
  error?: string;
  templateId?: string;
  revisionId?: string;
  contentHash?: string;
};

const fieldClass = "mt-2 h-11 w-full rounded-lg border border-line bg-white px-3 text-sm outline-none transition focus:border-brand-500 focus:ring-2 focus:ring-brand-100 disabled:bg-slate-50 disabled:text-slate-400";

async function postJson(path: string, body: unknown) {
  const response = await fetch(path, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Duindorp-CSRF": "same-origin",
      "X-Correlation-Id": crypto.randomUUID(),
    },
    body: JSON.stringify(body),
  });
  const payload = await response.json() as MutationResponse;
  if (!response.ok) throw new Error(payload.error ?? "De pakketwijziging kon niet worden opgeslagen.");
  return payload;
}

function statusLabel(revision: Revision) {
  if (revision.status === "draft") return "Concept";
  if (revision.status === "archived") return "Gearchiveerd";
  if (revision.default) return "Standaard";
  if (revision.active) return "Actief";
  return "Historisch";
}

function revisionTone(revision: Revision) {
  if (revision.default) return "bg-brand-50 text-brand-700";
  if (revision.status === "draft") return "bg-amber-50 text-amber-800";
  if (revision.active) return "bg-emerald-50 text-success";
  return "bg-slate-100 text-slate-500";
}

export function PackageWorkspace({ workspace }: { workspace: PackageWorkspaceData }) {
  const router = useRouter();
  const initialRevision = workspace.templates.flatMap((template) => template.revisions)
    .find((revision) => revision.status === "draft")
    ?? workspace.templates.flatMap((template) => template.revisions).find((revision) => revision.default)
    ?? workspace.templates[0]?.revisions[0];
  const [selectedRevisionId, setSelectedRevisionId] = useState<string | "new">(initialRevision?.id ?? "new");
  const [notice, setNotice] = useState<Notice>(null);
  const [saving, setSaving] = useState(false);
  const selection = useMemo(() => {
    for (const template of workspace.templates) {
      const revision = template.revisions.find((item) => item.id === selectedRevisionId);
      if (revision) return { template, revision };
    }
    return null;
  }, [selectedRevisionId, workspace.templates]);
  const publishedCount = workspace.templates.flatMap((template) => template.revisions).filter((revision) => revision.status === "published").length;
  const draftCount = workspace.templates.flatMap((template) => template.revisions).filter((revision) => revision.status === "draft").length;

  async function mutate(path: string, body: unknown, success: string) {
    setSaving(true);
    setNotice(null);
    try {
      const result = await postJson(path, body);
      if (result.revisionId) setSelectedRevisionId(result.revisionId);
      setNotice({ tone: "success", text: success });
      router.refresh();
      return true;
    } catch (error) {
      setNotice({ tone: "error", text: error instanceof Error ? error.message : "De pakketwijziging kon niet worden opgeslagen." });
      return false;
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="mx-auto max-w-[1400px]">
      <header className="flex flex-col gap-5 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p className="text-xs font-semibold uppercase tracking-[0.12em] text-brand-500">Commercieel product</p>
          <h1 className="mt-2 text-[30px] font-bold tracking-[-0.04em] text-brand-900 md:text-[34px]">Kledingpakketten</h1>
          <p className="mt-2 max-w-2xl text-sm text-slate-500">Stel zelf pakketnaam, prijs en producten samen. Maten worden per lid gekozen en staan nooit in de template.</p>
        </div>
        <button
          type="button"
          onClick={() => { setSelectedRevisionId("new"); setNotice(null); }}
          disabled={!workspace.seasons.some((season) => season.status === "open")}
          className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:opacity-50"
        >
          <Plus className="size-4" /> Nieuw pakket
        </button>
      </header>

      {notice && (
        <div role={notice.tone === "error" ? "alert" : "status"} className={"mt-6 flex items-start gap-2 rounded-xl border p-4 text-xs " + (notice.tone === "error" ? "border-red-100 bg-red-50 text-danger" : "border-emerald-100 bg-emerald-50 text-success")}>
          {notice.tone === "error" ? <AlertTriangle className="size-4 shrink-0" /> : <CheckCircle2 className="size-4 shrink-0" />}
          {notice.text}
        </div>
      )}

      <section className="mt-6 grid gap-4 sm:grid-cols-3">
        {[
          { label: "Pakkettypes", value: workspace.templates.length },
          { label: "Gepubliceerde revisies", value: publishedCount },
          { label: "Open concepten", value: draftCount },
        ].map((metric) => (
          <div key={metric.label} className="rounded-xl border border-line bg-white px-5 py-4 shadow-card">
            <p className="text-[10px] font-bold uppercase tracking-[0.1em] text-slate-400">{metric.label}</p>
            <p className="mt-2 text-2xl font-bold text-brand-900">{metric.value}</p>
          </div>
        ))}
      </section>

      <div className="mt-6 grid items-start gap-6 xl:grid-cols-[360px_minmax(0,1fr)]">
        <aside className="overflow-hidden rounded-xl border border-line bg-white shadow-card">
          <div className="border-b border-line px-5 py-4">
            <h2 className="text-sm font-bold text-brand-900">Pakketten en revisies</h2>
            <p className="mt-1 text-[11px] text-slate-400">Gepubliceerde inhoud blijft historisch intact.</p>
          </div>
          {workspace.templates.length === 0 ? (
            <div className="px-6 py-16 text-center">
              <Package className="mx-auto size-9 text-slate-300" />
              <p className="mt-4 text-sm font-semibold text-slate-600">Nog geen pakketten</p>
              <p className="mt-1 text-xs leading-5 text-slate-400">Je bepaalt zelf welke pakkettypes worden aangeboden.</p>
            </div>
          ) : (
            <div className="divide-y divide-line">
              {workspace.templates.map((template) => (
                <div key={template.id} className="p-4">
                  <div className="flex items-center justify-between gap-3">
                    <div className="min-w-0">
                      <p className="truncate text-sm font-bold text-brand-900">{template.revisions[0]?.name ?? template.key}</p>
                      <p className="mt-0.5 text-[10px] uppercase tracking-[0.08em] text-slate-400">{template.seasonName} · {template.key}</p>
                    </div>
                    <History className="size-4 shrink-0 text-slate-300" />
                  </div>
                  <div className="mt-3 space-y-1.5">
                    {template.revisions.map((revision) => (
                      <button
                        key={revision.id}
                        type="button"
                        onClick={() => { setSelectedRevisionId(revision.id); setNotice(null); }}
                        className={"flex w-full items-center gap-3 rounded-lg border px-3 py-2.5 text-left transition " + (selectedRevisionId === revision.id ? "border-brand-200 bg-brand-50" : "border-transparent hover:bg-slate-50")}
                      >
                        <span className="min-w-0 flex-1">
                          <span className="block truncate text-xs font-semibold text-ink">Revisie {revision.revisionNumber} · {revision.name}</span>
                          <span className="mt-0.5 block text-[10px] text-slate-400">€ {formatPackagePrice(revision.priceCents)}</span>
                        </span>
                        <span className={"rounded-full px-2 py-1 text-[9px] font-bold " + revisionTone(revision)}>{statusLabel(revision)}</span>
                      </button>
                    ))}
                  </div>
                </div>
              ))}
            </div>
          )}
        </aside>

        {selectedRevisionId === "new" ? (
          <PackageEditor
            key="new"
            workspace={workspace}
            saving={saving}
            onSave={(body) => mutate("/api/packages/draft", body, "Pakketconcept aangemaakt.")}
            onPublish={(body) => mutate("/api/packages/publish", body, "Pakketrevisie definitief gepubliceerd.")}
          />
        ) : selection?.revision.status === "draft" ? (
          <PackageEditor
            key={selection.revision.id}
            workspace={workspace}
            template={selection.template}
            revision={selection.revision}
            saving={saving}
            onSave={(body) => mutate("/api/packages/draft", body, "Pakketconcept bijgewerkt.")}
            onPublish={(body) => mutate("/api/packages/publish", body, "Pakketrevisie definitief gepubliceerd.")}
          />
        ) : selection ? (
          <PublishedRevision
            template={selection.template}
            revision={selection.revision}
            saving={saving}
            onClone={() => mutate("/api/packages/revision", {
              templateId: selection.template.id,
              sourceRevisionId: selection.revision.id,
              expectedHash: selection.revision.contentHash,
            }, "Nieuwe conceptrevisie aangemaakt.")}
            onArchive={(reason) => mutate("/api/packages/archive", {
              revisionId: selection.revision.id,
              reason,
              expectedHash: selection.revision.contentHash,
            }, "Pakketrevisie gearchiveerd.")}
          />
        ) : (
          <div className="rounded-xl border border-line bg-white p-8 text-sm text-slate-500 shadow-card">Selecteer een actuele revisie.</div>
        )}
      </div>
    </div>
  );
}

function PackageEditor({
  workspace,
  template,
  revision,
  saving,
  onSave,
  onPublish,
}: {
  workspace: PackageWorkspaceData;
  template?: Template;
  revision?: Revision;
  saving: boolean;
  onSave: (body: unknown) => Promise<boolean>;
  onPublish: (body: unknown) => Promise<boolean>;
}) {
  const openSeasons = workspace.seasons.filter((season) => season.status === "open");
  const [seasonId, setSeasonId] = useState(revision ? template?.seasonId ?? "" : workspace.activeSeason?.id ?? openSeasons[0]?.id ?? "");
  const [key, setKey] = useState(template?.key ?? "");
  const [name, setName] = useState(revision?.name ?? "");
  const [description, setDescription] = useState(revision?.description ?? "");
  const [price, setPrice] = useState(revision ? formatPackagePrice(revision.priceCents) : "");
  const [items, setItems] = useState<Record<string, number>>(() => Object.fromEntries(revision?.items.map((item) => [item.articleId, item.quantity]) ?? []));
  const [confirmPublish, setConfirmPublish] = useState(false);
  const [makeDefault, setMakeDefault] = useState(false);
  const [localError, setLocalError] = useState<string | null>(null);

  const products = workspace.articles.filter((article) => article.active && article.seasonIds.includes(seasonId));
  const eligibleProducts = products.filter((article) => article.sizes.some((size) => size.active));
  const requiresDefaultSelection =
    packageSeasonRequiresExplicitDefault(workspace, seasonId);

  function toggleProduct(articleId: string, checked: boolean) {
    setItems((current) => {
      const next = { ...current };
      if (checked) next[articleId] = current[articleId] ?? 1;
      else delete next[articleId];
      return next;
    });
  }

  function draftBody() {
    const priceCents = parsePackagePriceToCents(price);
    if (priceCents === null) throw new Error("Vul een geldig pakketbedrag met maximaal twee decimalen in.");
    const selected = eligibleProducts.filter((article) => items[article.id] !== undefined);
    if (selected.length === 0) throw new Error("Selecteer minimaal één actief product met een actieve maat.");
    return {
      templateId: template?.id ?? null,
      revisionId: revision?.id ?? null,
      seasonId,
      key,
      name,
      description,
      priceCents,
      items: selected.map((article, index) => ({
        articleId: article.id,
        quantity: items[article.id],
        sortOrder: (index + 1) * 10,
      })),
      expectedHash: revision?.contentHash ?? null,
    };
  }

  async function submit(event: FormEvent) {
    event.preventDefault();
    setLocalError(null);
    try {
      await onSave(draftBody());
    } catch (error) {
      setLocalError(error instanceof Error ? error.message : "Controleer de pakketgegevens.");
    }
  }

  async function publish() {
    if (!revision) return;
    setLocalError(null);
    if (requiresDefaultSelection && !makeDefault) {
      setLocalError(
        "Kies expliciet het standaardpakket voordat je het eerste pakket in dit seizoen publiceert.",
      );
      return;
    }
    const success = await onPublish({
      revisionId: revision.id,
      makeDefault,
      expectedHash: revision.contentHash,
    });
    if (success) setConfirmPublish(false);
  }

  return (
    <form onSubmit={submit} className="overflow-hidden rounded-xl border border-line bg-white shadow-card">
      <div className="flex flex-col gap-3 border-b border-line px-6 py-5 sm:flex-row sm:items-start sm:justify-between">
        <div className="flex items-start gap-3">
          <span className="flex size-10 shrink-0 items-center justify-center rounded-xl bg-brand-50 text-brand-700"><Edit3 className="size-5" /></span>
          <div>
            <p className="text-[10px] font-bold uppercase tracking-[0.12em] text-brand-500">{revision ? `Conceptrevisie ${revision.revisionNumber}` : "Nieuw pakket"}</p>
            <h2 className="mt-1 text-lg font-bold text-brand-900">{revision?.name ?? "Pakket samenstellen"}</h2>
            <p className="mt-1 text-xs text-slate-500">Opslaan blijft een concept; publiceren maakt een immutable revisie.</p>
          </div>
        </div>
        {revision && <span className="rounded-full bg-amber-50 px-3 py-1 text-[10px] font-bold text-amber-800">Concept</span>}
      </div>

      {(localError || openSeasons.length === 0) && (
        <div role="alert" className="mx-6 mt-5 flex gap-2 rounded-lg border border-amber-200 bg-amber-50 p-4 text-xs text-amber-900">
          <AlertTriangle className="size-4 shrink-0" />
          {localError ?? "Er is geen open seizoen waarin een pakket kan worden beheerd."}
        </div>
      )}

      <fieldset disabled={saving || openSeasons.length === 0} className="p-6">
        <div className="grid gap-4 sm:grid-cols-2">
          <label className="text-xs font-semibold text-ink">Seizoen
            <select value={seasonId} onChange={(event) => { setSeasonId(event.target.value); setItems({}); }} disabled={Boolean(revision)} className={fieldClass}>
              {openSeasons.map((season) => <option key={season.id} value={season.id}>{season.name}{season.active ? " · actief" : ""}</option>)}
            </select>
          </label>
          <label className="text-xs font-semibold text-ink">Interne pakketcode
            <input value={key} onChange={(event) => setKey(event.target.value.toLowerCase().replace(/\s+/g, "_"))} required minLength={2} maxLength={64} pattern="[a-z0-9][a-z0-9_-]{1,63}" placeholder="bijv. speler" className={fieldClass} />
          </label>
          <label className="text-xs font-semibold text-ink">Pakketnaam
            <input value={name} onChange={(event) => setName(event.target.value)} required maxLength={120} placeholder="Bijv. Speler" className={fieldClass} />
          </label>
          <label className="text-xs font-semibold text-ink">Pakketprijs in euro
            <div className="relative"><span className="pointer-events-none absolute left-3 top-[22px] text-sm text-slate-400">€</span><input value={price} onChange={(event) => setPrice(event.target.value)} required inputMode="decimal" placeholder="0,00" className={fieldClass + " pl-8"} /></div>
          </label>
          <label className="text-xs font-semibold text-ink sm:col-span-2">Omschrijving
            <textarea value={description} onChange={(event) => setDescription(event.target.value)} maxLength={2000} rows={4} className="mt-2 w-full rounded-lg border border-line bg-white px-3 py-3 text-sm outline-none transition focus:border-brand-500 focus:ring-2 focus:ring-brand-100" />
          </label>
        </div>

        <div className="mt-7 border-t border-line pt-6">
          <div className="flex items-start justify-between gap-4">
            <div><h3 className="text-sm font-bold text-brand-900">Productinhoud</h3><p className="mt-1 text-xs text-slate-500">Selecteer aantallen; de maat kiest ieder lid later per product.</p></div>
            <span className="rounded-full bg-slate-100 px-3 py-1 text-[10px] font-bold text-slate-500">{Object.keys(items).length} geselecteerd</span>
          </div>
          {products.length === 0 ? (
            <div className="mt-4 rounded-lg border border-dashed border-line p-6 text-center">
              <Shirt className="mx-auto size-7 text-slate-300" />
              <p className="mt-3 text-xs font-semibold text-slate-600">Geen actieve producten in dit seizoen</p>
              <Link href="/backoffice/artikelen" className="mt-2 inline-block text-xs font-semibold text-brand-700 hover:underline">Producten en maten beheren</Link>
            </div>
          ) : (
            <div className="mt-4 grid gap-3 sm:grid-cols-2">
              {products.map((article) => {
                const activeSizes = article.sizes.filter((size) => size.active);
                const eligible = activeSizes.length > 0;
                const checked = items[article.id] !== undefined;
                return (
                  <div key={article.id} className={"rounded-lg border p-4 " + (checked ? "border-brand-200 bg-brand-50/40" : "border-line")}>
                    <label className={"flex items-start gap-3 " + (eligible ? "cursor-pointer" : "cursor-not-allowed opacity-60")}>
                      <input type="checkbox" checked={checked} disabled={!eligible} onChange={(event) => toggleProduct(article.id, event.target.checked)} className="mt-0.5 size-4 accent-brand-700" />
                      <span className="min-w-0 flex-1">
                        <span className="block truncate text-xs font-bold text-ink">{article.name}</span>
                        <span className="mt-1 block text-[10px] text-slate-400">{eligible ? `${activeSizes.length} actieve maten: ${activeSizes.slice(0, 6).map((size) => size.label).join(", ")}${activeSizes.length > 6 ? "…" : ""}` : "Voeg eerst een actieve maat toe"}</span>
                      </span>
                    </label>
                    {checked && <label className="mt-3 flex items-center justify-between gap-4 border-t border-brand-100 pt-3 text-[11px] font-semibold text-slate-600">Aantal<input type="number" min={1} max={25} value={items[article.id]} onChange={(event) => setItems((current) => ({ ...current, [article.id]: Number(event.target.value) }))} className="h-9 w-20 rounded-lg border border-line bg-white px-2 text-sm" /></label>}
                  </div>
                );
              })}
            </div>
          )}
        </div>
      </fieldset>

      <div className="flex flex-col gap-3 border-t border-line bg-slate-50/60 px-6 py-5 sm:flex-row sm:items-center sm:justify-between">
        {revision ? (
          <button type="button" onClick={() => setConfirmPublish((current) => !current)} disabled={saving} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-brand-200 bg-white px-4 text-xs font-semibold text-brand-700 hover:border-brand-500 disabled:opacity-50">
            <Send className="size-4" /> Publicatie voorbereiden
          </button>
        ) : <span className="text-[11px] text-slate-400">Na opslaan kies je bij publicatie expliciet of dit het standaardpakket wordt.</span>}
        <button type="submit" disabled={saving || eligibleProducts.length === 0} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 disabled:opacity-50">
          {saving ? <Loader2 className="size-4 animate-spin" /> : <Save className="size-4" />} Concept opslaan
        </button>
      </div>

      {revision && confirmPublish && (
        <div className="border-t border-amber-200 bg-amber-50 p-6">
          <h3 className="text-sm font-bold text-amber-950">Definitief publiceren?</h3>
          <p className="mt-1 text-xs leading-5 text-amber-900">Sla je laatste wijzigingen eerst op. Na publicatie zijn naam, prijs en inhoud van deze revisie niet meer wijzigbaar.</p>
          <label className="mt-4 flex items-center gap-3 text-xs font-semibold text-amber-950"><input type="checkbox" checked={makeDefault} onChange={(event) => setMakeDefault(event.target.checked)} className="size-4 accent-brand-700" /> Maak dit het standaardpakket voor dit seizoen</label>
          {requiresDefaultSelection && (
            <p role="note" className="mt-2 text-xs font-semibold text-amber-950">
              Dit seizoen heeft nog geen standaardpakket. Deze keuze is daarom verplicht.
            </p>
          )}
          <div className="mt-4 flex justify-end gap-2">
            <button type="button" onClick={() => setConfirmPublish(false)} className="h-9 rounded-lg border border-amber-300 bg-white px-4 text-xs font-semibold text-amber-900">Annuleren</button>
            <button type="button" onClick={() => void publish()} disabled={saving || (requiresDefaultSelection && !makeDefault)} className="inline-flex h-9 items-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 disabled:opacity-50"><CheckCircle2 className="size-4" /> Definitief publiceren</button>
          </div>
        </div>
      )}
    </form>
  );
}

function PublishedRevision({
  template,
  revision,
  saving,
  onClone,
  onArchive,
}: {
  template: Template;
  revision: Revision;
  saving: boolean;
  onClone: () => Promise<boolean>;
  onArchive: (reason: string) => Promise<boolean>;
}) {
  const [archiveReason, setArchiveReason] = useState("");
  const [showArchive, setShowArchive] = useState(false);
  const canClone = revision.id === template.revisions[0]?.id
    && revision.status !== "draft"
    && !template.revisions.some((item) => item.status === "draft");
  const canArchive = revision.status === "published" && !revision.default;
  return (
    <section className="overflow-hidden rounded-xl border border-line bg-white shadow-card">
      <div className="flex flex-col gap-4 border-b border-line px-6 py-5 sm:flex-row sm:items-start sm:justify-between">
        <div className="flex items-start gap-3">
          <span className="flex size-10 shrink-0 items-center justify-center rounded-xl bg-brand-50 text-brand-700">{revision.default ? <Crown className="size-5" /> : <Package className="size-5" />}</span>
          <div>
            <div className="flex flex-wrap items-center gap-2"><h2 className="text-lg font-bold text-brand-900">{revision.name}</h2><span className={"rounded-full px-2.5 py-1 text-[9px] font-bold " + revisionTone(revision)}>{statusLabel(revision)}</span></div>
            <p className="mt-1 text-xs text-slate-500">{template.seasonName} · revisie {revision.revisionNumber} · code {template.key}</p>
          </div>
        </div>
        <p className="text-2xl font-bold text-brand-900">€ {formatPackagePrice(revision.priceCents)}</p>
      </div>

      <div className="p-6">
        {revision.description && <p className="rounded-lg bg-slate-50 p-4 text-sm leading-6 text-slate-600">{revision.description}</p>}
        <h3 className="mt-6 text-sm font-bold text-brand-900">Historische inhoudsnapshot</h3>
        <div className="mt-3 overflow-hidden rounded-lg border border-line">
          <table className="w-full text-left">
            <thead><tr className="border-b border-line bg-slate-50 text-[10px] font-bold uppercase tracking-[0.08em] text-slate-400"><th className="px-4 py-3">Product</th><th className="px-4 py-3">Code</th><th className="px-4 py-3 text-right">Aantal</th></tr></thead>
            <tbody className="divide-y divide-line">
              {revision.items.map((item) => <tr key={item.id}><td className="px-4 py-3 text-xs font-semibold text-ink">{item.productName}</td><td className="px-4 py-3 text-xs text-slate-500">{item.productCode}</td><td className="px-4 py-3 text-right text-xs font-bold text-brand-900">{item.quantity}</td></tr>)}
            </tbody>
          </table>
        </div>
        <div className="mt-4 rounded-lg border border-brand-100 bg-brand-50/50 p-4 text-xs leading-5 text-brand-900">
          Productnamen, codes, prijs en aantallen van deze revisie blijven onveranderd. Maten worden afzonderlijk per lid-seizoen vastgelegd.
        </div>
      </div>

      <div className="flex flex-col gap-3 border-t border-line bg-slate-50/60 px-6 py-5 sm:flex-row sm:justify-end">
        {canArchive && <button type="button" onClick={() => setShowArchive((current) => !current)} disabled={saving} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-line bg-white px-4 text-xs font-semibold text-slate-600 hover:border-red-200 hover:text-danger"><Archive className="size-4" /> Archiveren</button>}
        {canClone && <button type="button" onClick={() => void onClone()} disabled={saving} className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 disabled:opacity-50">{saving ? <Loader2 className="size-4 animate-spin" /> : <CopyPlus className="size-4" />} Nieuwe revisie</button>}
      </div>
      {showArchive && (
        <form onSubmit={(event) => { event.preventDefault(); void onArchive(archiveReason); }} className="border-t border-red-100 bg-red-50 p-6">
          <label className="text-xs font-semibold text-red-950">Reden voor archivering<input value={archiveReason} onChange={(event) => setArchiveReason(event.target.value)} required minLength={3} maxLength={500} className={fieldClass} /></label>
          <p className="mt-2 text-[11px] text-red-800">Historische orders en snapshots blijven behouden. Een standaardpakket kan niet worden gearchiveerd.</p>
          <div className="mt-4 flex justify-end gap-2"><button type="button" onClick={() => setShowArchive(false)} className="h-9 rounded-lg border border-red-200 bg-white px-4 text-xs font-semibold text-red-900">Annuleren</button><button type="submit" disabled={saving} className="inline-flex h-9 items-center gap-2 rounded-lg bg-danger px-4 text-xs font-semibold text-white disabled:opacity-50"><Archive className="size-4" /> Archiveren met reden</button></div>
        </form>
      )}
    </section>
  );
}
