"use client";

import { CheckCircle2, FileSpreadsheet, Loader2, UploadCloud, XCircle } from "lucide-react";
import { useState } from "react";

type PreviewResponse = {
  summary: { total: number; valid: number; invalid: number; duplicates: number };
  members: Array<{ relationNumber: string; firstName: string; lastName: string; email: string; team: string }>;
  issues: Array<{ row: number; field?: string; message: string }>;
};

export function ImportPanel() {
  const [file, setFile] = useState<File | null>(null);
  const [preview, setPreview] = useState<PreviewResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(false);

  async function handlePreview() {
    if (!file) return;
    setError(null);
    setPreview(null);
    setIsLoading(true);
    const formData = new FormData();
    formData.append("file", file);
    try {
      const response = await fetch("/api/imports/preview", { method: "POST", body: formData });
      const payload = await response.json() as PreviewResponse & { error?: string };
      if (!response.ok) throw new Error(payload.error ?? "Preview kon niet worden gemaakt.");
      setPreview(payload);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Preview kon niet worden gemaakt.");
    } finally {
      setIsLoading(false);
    }
  }

  return <section className="rounded-xl border border-line bg-white p-5 shadow-card"><div className="flex items-start justify-between gap-4"><div><h2 className="text-base font-bold text-brand-900">Sportlink importeren</h2><p className="mt-1 text-xs leading-5 text-slate-500">Upload een CSV, controleer de preview en commit daarna pas de wijzigingen.</p></div><FileSpreadsheet className="size-5 text-brand-500" /></div><label className="mt-5 flex min-h-[116px] cursor-pointer flex-col items-center justify-center rounded-xl border border-dashed border-brand-200 bg-brand-50/50 px-5 text-center transition-colors hover:border-brand-500 hover:bg-brand-50"><UploadCloud className="size-6 text-brand-500" /><span className="mt-2 text-xs font-semibold text-brand-700">{file ? file.name : "Kies een CSV-bestand"}</span><span className="mt-1 text-[11px] text-slate-400">UTF-8 · maximaal 10 MB</span><input type="file" accept=".csv,text/csv" className="sr-only" onChange={(event) => { setFile(event.target.files?.[0] ?? null); setPreview(null); setError(null); }} /></label><button disabled={!file || isLoading} onClick={handlePreview} className="mt-4 inline-flex h-10 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 text-xs font-semibold text-white transition-colors hover:bg-brand-900 disabled:cursor-not-allowed disabled:bg-slate-200 disabled:text-slate-400">{isLoading && <Loader2 className="size-4 animate-spin" />}{isLoading ? "Preview maken…" : "Preview controleren"}</button>{error && <div className="mt-4 flex items-start gap-2 rounded-lg bg-red-50 p-3 text-xs text-danger"><XCircle className="mt-0.5 size-4 shrink-0" /><span>{error}</span></div>}{preview && <div className="mt-4 rounded-lg border border-emerald-100 bg-emerald-50/60 p-4"><div className="flex items-center gap-2 text-xs font-bold text-success"><CheckCircle2 className="size-4" /> Preview gereed</div><div className="mt-3 grid grid-cols-3 gap-2 text-center"><div><p className="text-lg font-bold text-ink">{preview.summary.total}</p><p className="text-[10px] text-slate-500">Rijen</p></div><div><p className="text-lg font-bold text-success">{preview.summary.valid}</p><p className="text-[10px] text-slate-500">Geldig</p></div><div><p className="text-lg font-bold text-danger">{preview.summary.invalid}</p><p className="text-[10px] text-slate-500">Ongeldig</p></div></div></div>}</section>;
}
