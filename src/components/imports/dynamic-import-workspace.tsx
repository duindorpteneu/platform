"use client";

import {
  AlertTriangle,
  ArrowLeft,
  CheckCircle2,
  FileSpreadsheet,
  Loader2,
  ShieldCheck,
  UploadCloud,
  XCircle,
} from "lucide-react";
import Link from "next/link";
import { useState } from "react";
import {
  dynamicImportUploadResponseSchema,
  type DynamicImportUploadResponse,
  type DynamicImportWorkspaceData,
} from "@/lib/import-contract";

const steps = ["Bestand", "Kolommen", "Dry-run", "Verwerken"];

function formatBytes(bytes: number) {
  return new Intl.NumberFormat("nl-NL", { maximumFractionDigits: 1 }).format(bytes / 1024);
}

export function DynamicImportWorkspace({ workspace }: { workspace: DynamicImportWorkspaceData }) {
  const [file, setFile] = useState<File | null>(null);
  const [requestId, setRequestId] = useState(() => crypto.randomUUID());
  const [upload, setUpload] = useState<DynamicImportUploadResponse | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const enabled = workspace.featureEnabled && Boolean(workspace.activeSeason);

  async function stageUpload() {
    if (!file || !workspace.activeSeason) return;
    setBusy(true);
    setError(null);
    try {
      const response = await fetch("/api/imports/uploads", {
        method: "POST",
        headers: {
          "Content-Type": file.type || "text/csv",
          "X-Duindorp-CSRF": "same-origin",
          "X-Duindorp-File-Name": encodeURIComponent(file.name),
          "X-Duindorp-Idempotency-Key": requestId,
        },
        body: file,
      });
      const body: unknown = await response.json();
      if (!response.ok) {
        const message = body && typeof body === "object" && "error" in body && typeof body.error === "string"
          ? body.error
          : "De upload kon niet veilig worden klaargezet.";
        throw new Error(message);
      }
      const parsed = dynamicImportUploadResponseSchema.safeParse(body);
      if (!parsed.success) throw new Error("De server gaf een ongeldig uploadresultaat terug.");
      setUpload(parsed.data);
    } catch (cause) {
      setUpload(null);
      setError(cause instanceof Error ? cause.message : "De upload kon niet veilig worden klaargezet.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="mx-auto max-w-[1440px]">
      <Link href="/backoffice/leden" className="inline-flex items-center gap-2 text-xs font-semibold text-brand-700 hover:text-brand-900">
        <ArrowLeft className="size-3.5" /> Terug naar leden
      </Link>
      <div className="mt-5">
        <p className="text-xs font-semibold uppercase tracking-[0.12em] text-brand-500">Ledenbeheer</p>
        <h1 className="mt-2 text-[30px] font-bold tracking-[-0.04em] text-brand-900 md:text-[34px]">Sportlink importeren</h1>
        <p className="mt-2 max-w-3xl text-sm leading-6 text-slate-500">
          Koppel alleen de benodigde CSV-kolommen. De upload activeert nooit portaaltoegang en verstuurt geen e-mail.
        </p>
      </div>

      <ol className="mt-7 grid grid-cols-4 gap-2 rounded-xl border border-line bg-white p-4 shadow-card" aria-label="Importstappen">
        {steps.map((step, index) => {
          const reached = index === 0 || (index === 1 && upload);
          return (
            <li key={step} className="flex min-w-0 items-center gap-2">
              <span className={`flex size-7 shrink-0 items-center justify-center rounded-full text-[11px] font-bold ${reached ? "bg-brand-700 text-white" : "bg-slate-100 text-slate-400"}`}>{index + 1}</span>
              <span className={`truncate text-[11px] font-semibold ${reached ? "text-brand-900" : "text-slate-400"}`}>{step}</span>
            </li>
          );
        })}
      </ol>

      {!workspace.featureEnabled && (
        <section className="mt-6 flex items-start gap-3 rounded-xl border border-amber-200 bg-amber-50 p-5" role="status">
          <AlertTriangle className="mt-0.5 size-5 shrink-0 text-amber-700" />
          <div><h2 className="text-sm font-bold text-amber-950">Import veilig gepauzeerd</h2><p className="mt-1 text-xs leading-5 text-amber-900">De runtime- en databasepoort moeten beide actief zijn. Bestaande leden blijven ongewijzigd.</p></div>
        </section>
      )}
      {!workspace.activeSeason && (
        <section className="mt-6 flex items-start gap-3 rounded-xl border border-red-100 bg-red-50 p-5" role="alert">
          <XCircle className="mt-0.5 size-5 shrink-0 text-danger" />
          <div><h2 className="text-sm font-bold text-red-950">Geen open actief seizoen</h2><p className="mt-1 text-xs leading-5 text-red-900">Activeer eerst het seizoen waarin de lid-seizoenrelaties en maten moeten worden verwerkt.</p></div>
        </section>
      )}

      <div className="mt-6 grid items-start gap-6 xl:grid-cols-[minmax(0,1fr)_320px]">
        <section className="rounded-xl border border-line bg-white p-5 shadow-card md:p-6">
          <div className="flex items-start justify-between gap-4">
            <div><p className="text-[11px] font-semibold uppercase tracking-[0.1em] text-brand-500">Stap 1</p><h2 className="mt-1 text-lg font-bold text-brand-900">Bestand en diagnose</h2><p className="mt-1 text-xs leading-5 text-slate-500">Alleen strikt UTF-8 CSV; komma en puntkomma worden ondersteund.</p></div>
            <FileSpreadsheet className="size-5 text-brand-500" />
          </div>

          <label className={`mt-5 flex min-h-36 flex-col items-center justify-center rounded-xl border border-dashed px-5 text-center transition-colors ${enabled ? "cursor-pointer border-brand-200 bg-brand-50/50 hover:border-brand-500 hover:bg-brand-50" : "cursor-not-allowed border-slate-200 bg-slate-50"}`}>
            <UploadCloud className="size-7 text-brand-500" />
            <span className="mt-2 text-sm font-semibold text-brand-800">{file?.name ?? "Kies een Sportlink CSV-bestand"}</span>
            <span className="mt-1 text-[11px] text-slate-400">Maximaal 10 MB · 10.000 rijen · 64 kolommen</span>
            <input
              type="file"
              accept=".csv,text/csv,application/csv,application/vnd.ms-excel"
              disabled={!enabled}
              className="sr-only"
              onChange={(event) => {
                setFile(event.target.files?.[0] ?? null);
                setRequestId(crypto.randomUUID());
                setUpload(null);
                setError(null);
              }}
            />
          </label>
          <button
            type="button"
            disabled={!file || busy || !enabled}
            onClick={() => void stageUpload()}
            className="mt-4 inline-flex h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white transition-colors hover:bg-brand-900 disabled:cursor-not-allowed disabled:bg-slate-200 disabled:text-slate-400"
          >
            {busy && <Loader2 className="size-4 animate-spin" />}
            {busy ? "Veilig uploaden en controleren…" : upload ? "Bestand opnieuw controleren" : "Uploaden en controleren"}
          </button>
          {error && <div className="mt-4 flex items-start gap-2 rounded-lg bg-red-50 p-3 text-xs text-danger" role="alert"><XCircle className="mt-0.5 size-4 shrink-0" /><span>{error}</span></div>}

          {upload && (
            <div className="mt-5 space-y-5" aria-live="polite">
              <div className="flex items-start gap-3 rounded-lg border border-emerald-100 bg-emerald-50 p-4">
                <CheckCircle2 className="mt-0.5 size-5 shrink-0 text-success" />
                <div><h3 className="text-sm font-bold text-emerald-950">Versleuteld klaargezet</h3><p className="mt-1 text-xs leading-5 text-emerald-900">Ruwe gegevens worden uiterlijk {new Date(upload.expiresAt).toLocaleString("nl-NL")} automatisch verwijderd.</p></div>
              </div>
              <dl className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
                {[
                  ["Bestand", upload.diagnosis.fileName],
                  ["Omvang", `${formatBytes(upload.diagnosis.byteCount)} KB`],
                  ["Rijen", upload.diagnosis.rowCount.toLocaleString("nl-NL")],
                  ["Kolommen", upload.diagnosis.columnCount.toLocaleString("nl-NL")],
                  ["Encoding", upload.diagnosis.encoding],
                  ["Scheidingsteken", upload.diagnosis.delimiter === ";" ? "Puntkomma" : "Komma"],
                ].map(([label, value]) => <div key={label} className="rounded-lg border border-line bg-slate-50 p-3"><dt className="text-[10px] font-semibold uppercase tracking-[0.08em] text-slate-400">{label}</dt><dd className="mt-1 truncate text-xs font-semibold text-ink">{value}</dd></div>)}
              </dl>
              {upload.diagnosis.rowShapeIssues.length > 0 && <div className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-xs text-amber-900"><strong>{upload.diagnosis.rowShapeIssues.length} rijen</strong> hebben een afwijkend aantal kolommen en worden in de dry-run als fout gemarkeerd.</div>}
              <div>
                <h3 className="text-sm font-bold text-brand-900">Bronkolommen</h3>
                <p className="mt-1 text-xs text-slate-500">Waarden zijn alleen in deze beheerderssessie zichtbaar en worden pas na expliciete selectie verwerkt.</p>
                <div className="mt-3 grid gap-3 md:grid-cols-2">
                  {upload.columns.map((column) => (
                    <article key={column.index} className="rounded-lg border border-line p-4">
                      <div className="flex items-start justify-between gap-3"><h4 className="text-xs font-bold text-ink">{column.label}</h4><span className="rounded-full bg-slate-100 px-2 py-1 text-[9px] font-semibold text-slate-500">{column.uniqueValueCount} uniek</span></div>
                      <p className="mt-2 text-[10px] text-slate-400">{column.nonEmptyCount} gevuld · {column.emptyCount} leeg</p>
                      {column.uniqueValues.length > 0 && <p className="mt-2 line-clamp-2 text-[10px] leading-4 text-slate-500">{column.uniqueValues.slice(0, 5).join(" · ")}{column.uniqueValueCount > 5 ? " · …" : ""}</p>}
                    </article>
                  ))}
                </div>
              </div>
              <button type="button" disabled className="inline-flex h-11 w-full items-center justify-center rounded-lg bg-slate-200 px-4 text-xs font-semibold text-slate-500">Kolommen koppelen wordt na servervalidatie beschikbaar</button>
            </div>
          )}
        </section>

        <aside className="space-y-4 xl:sticky xl:top-6">
          <section className="rounded-xl border border-brand-100 bg-brand-50 p-5">
            <div className="flex items-center gap-2"><ShieldCheck className="size-4 text-brand-700" /><h2 className="text-sm font-bold text-brand-900">Vast importbeleid</h2></div>
            <ul className="mt-3 space-y-2 text-xs leading-5 text-brand-900">
              <li>Geen account, toegang of e-mail door import.</li>
              <li>Bevestigde maten worden nooit overschreven.</li>
              <li>Geen fuzzy maat- of identiteitsgok.</li>
              <li>Onbekende maat wordt een beheerconflict.</li>
              <li>Alle mutaties blijven seizoensgebonden.</li>
            </ul>
          </section>
          <section className="rounded-xl border border-line bg-white p-5 shadow-card">
            <h2 className="text-sm font-bold text-brand-900">Doelseizoen</h2>
            <p className="mt-2 text-xs text-slate-500">{workspace.activeSeason?.name ?? "Niet ingesteld"}</p>
            <p className="mt-4 text-[11px] leading-5 text-slate-400">Ruwe stagingretentie: maximaal {workspace.limits.retentionHoursDefault} uur. Genegeerde kolommen worden niet duurzaam overgenomen.</p>
          </section>
        </aside>
      </div>
    </main>
  );
}
