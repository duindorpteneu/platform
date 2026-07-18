"use client";

import { CheckCircle2, FileSpreadsheet, Loader2, UploadCloud, XCircle } from "lucide-react";
import { useRouter } from "next/navigation";
import { useState } from "react";

type PreviewResponse = {
  summary: { total: number; valid: number; invalid: number; duplicates: number; new: number; updated: number; unchanged: number };
  members: Array<{ relationNumber: string; firstName: string; lastName: string; email: string; team: string }>;
  issues: Array<{ row: number; field?: string; message: string }>;
};

export function ImportPanel() {
  const router = useRouter();
  const [file, setFile] = useState<File | null>(null);
  const [preview, setPreview] = useState<PreviewResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [busy, setBusy] = useState<"preview" | "commit" | null>(null);
  const [inputVersion, setInputVersion] = useState(0);

  function formDataForFile() {
    if (!file) return null;
    const formData = new FormData();
    formData.append("file", file);
    return formData;
  }

  async function handlePreview() {
    const formData = formDataForFile();
    if (!formData) return;
    setError(null);
    setSuccess(null);
    setPreview(null);
    setBusy("preview");
    try {
      const response = await fetch("/api/imports/preview", { method: "POST", headers: { "X-Duindorp-CSRF": "same-origin" }, body: formData });
      const payload = await response.json() as PreviewResponse & { error?: string };
      if (!response.ok) throw new Error(payload.error ?? "Preview kon niet worden gemaakt.");
      setPreview(payload);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Preview kon niet worden gemaakt.");
    } finally {
      setBusy(null);
    }
  }

  async function handleCommit() {
    const formData = formDataForFile();
    if (!formData || !preview || preview.summary.invalid > 0) return;
    setError(null);
    setSuccess(null);
    setBusy("commit");
    try {
      const response = await fetch("/api/imports/commit", { method: "POST", headers: { "X-Duindorp-CSRF": "same-origin" }, body: formData });
      const payload = await response.json() as { error?: string; upserted?: number };
      if (!response.ok) throw new Error(payload.error ?? "De import kon niet worden opgeslagen.");
      setSuccess(`${payload.upserted ?? preview.summary.valid} leden zijn transactioneel verwerkt.`);
      setFile(null);
      setPreview(null);
      setInputVersion((value) => value + 1);
      router.refresh();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "De import kon niet worden opgeslagen.");
    } finally {
      setBusy(null);
    }
  }

  return (
    <section className="rounded-xl border border-line bg-white p-5 shadow-card">
      <div className="flex items-start justify-between gap-4"><div><h2 className="text-base font-bold text-brand-900">Sportlink importeren</h2><p className="mt-1 text-xs leading-5 text-slate-500">Upload, controleer de herkende kolommen en bevestig pas daarna de transactie.</p></div><FileSpreadsheet className="size-5 text-brand-500" /></div>
      <ol className="mt-5 grid grid-cols-4 gap-1" aria-label="Importstappen">{["Upload", "Koppeling", "Preview", "Commit"].map((step, index) => {
        const reached = index === 0 || Boolean(file) || (index > 1 && Boolean(preview)) || (index === 3 && Boolean(success));
        return <li key={step} className="text-center"><div className={`mx-auto flex size-6 items-center justify-center rounded-full text-[10px] font-bold ${reached ? "bg-brand-700 text-white" : "bg-slate-100 text-slate-400"}`}>{index + 1}</div><p className="mt-1 text-[9px] font-semibold text-slate-400">{step}</p></li>;
      })}</ol>
      <label className="mt-5 flex min-h-[116px] cursor-pointer flex-col items-center justify-center rounded-xl border border-dashed border-brand-200 bg-brand-50/50 px-5 text-center transition-colors hover:border-brand-500 hover:bg-brand-50"><UploadCloud className="size-6 text-brand-500" /><span className="mt-2 text-xs font-semibold text-brand-700">{file ? file.name : "Kies een CSV-bestand"}</span><span className="mt-1 text-[11px] text-slate-400">UTF-8 · maximaal 10 MB</span><input key={inputVersion} type="file" accept=".csv,text/csv" className="sr-only" onChange={(event) => { setFile(event.target.files?.[0] ?? null); setPreview(null); setError(null); setSuccess(null); }} /></label>
      <button disabled={!file || busy !== null} onClick={() => void handlePreview()} className="mt-4 inline-flex h-10 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 text-xs font-semibold text-white transition-colors hover:bg-brand-900 disabled:cursor-not-allowed disabled:bg-slate-200 disabled:text-slate-400">{busy === "preview" && <Loader2 className="size-4 animate-spin" />}{busy === "preview" ? "Preview maken…" : preview ? "Preview opnieuw controleren" : "Kolommen en preview controleren"}</button>
      {error && <div role="alert" className="mt-4 flex items-start gap-2 rounded-lg bg-red-50 p-3 text-xs text-danger"><XCircle className="mt-0.5 size-4 shrink-0" /><span>{error}</span></div>}
      {success && <div role="status" className="mt-4 flex items-start gap-2 rounded-lg bg-emerald-50 p-3 text-xs text-success"><CheckCircle2 className="mt-0.5 size-4 shrink-0" /><span>{success}</span></div>}
      {preview && <div className="mt-4 rounded-lg border border-emerald-100 bg-emerald-50/60 p-4"><div className="flex items-center gap-2 text-xs font-bold text-success"><CheckCircle2 className="size-4" /> Kolommen gekoppeld en preview gereed</div><p className="mt-2 text-[10px] leading-4 text-slate-500">Relatienummer, naam, e-mail, team en seizoenstatus zijn herkend. Controleer de aantallen vóór commit.</p><div className="mt-3 grid grid-cols-3 gap-2 text-center"><div><p className="text-lg font-bold text-success">{preview.summary.new}</p><p className="text-[9px] text-slate-500">Nieuw</p></div><div><p className="text-lg font-bold text-brand-700">{preview.summary.updated}</p><p className="text-[9px] text-slate-500">Bijgewerkt</p></div><div><p className="text-lg font-bold text-ink">{preview.summary.unchanged}</p><p className="text-[9px] text-slate-500">Ongewijzigd</p></div><div><p className="text-lg font-bold text-ink">{preview.summary.total}</p><p className="text-[9px] text-slate-500">Rijen</p></div><div><p className="text-lg font-bold text-danger">{preview.summary.invalid}</p><p className="text-[9px] text-slate-500">Ongeldig</p></div><div><p className="text-lg font-bold text-warning">{preview.summary.duplicates}</p><p className="text-[9px] text-slate-500">Dubbel</p></div></div><button disabled={busy !== null || preview.summary.invalid > 0 || preview.summary.valid === 0} onClick={() => void handleCommit()} className="mt-4 inline-flex h-10 w-full items-center justify-center gap-2 rounded-lg bg-emerald-600 text-xs font-semibold text-white hover:bg-emerald-700 disabled:bg-slate-200 disabled:text-slate-400">{busy === "commit" && <Loader2 className="size-4 animate-spin" />}{busy === "commit" ? "Import verwerken…" : "Import definitief verwerken"}</button></div>}
    </section>
  );
}
