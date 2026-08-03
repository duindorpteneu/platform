"use client";

import { Loader2, Save } from "lucide-react";
import { FormEvent, useEffect, useState } from "react";

export function InventoryThresholdControl({
  seasonId,
  threshold,
  onSaved,
  onError,
}: {
  seasonId: string;
  threshold: number;
  onSaved: (message: string) => Promise<void>;
  onError: (message: string) => void;
}) {
  const [value, setValue] = useState(String(threshold));
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);

  useEffect(() => setValue(String(threshold)), [threshold, seasonId]);

  async function submit(event: FormEvent) {
    event.preventDefault();
    setSaving(true);
    try {
      const response = await fetch("/api/stock/settings", {
        method: "PUT",
        headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" },
        body: JSON.stringify({ seasonId, threshold: Number(value), reason }),
      });
      const payload = await response.json() as { error?: string };
      if (!response.ok) throw new Error(payload.error ?? "De lagevoorraaddrempel kon niet worden opgeslagen.");
      setReason("");
      await onSaved(`Lagevoorraaddrempel ingesteld op ${Number(value)} stuks.`);
    } catch (error) {
      onError(error instanceof Error ? error.message : "De lagevoorraaddrempel kon niet worden opgeslagen.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <form onSubmit={(event) => void submit(event)} className="mt-6 rounded-2xl border border-line bg-white p-5 shadow-card">
      <div className="flex flex-wrap items-end gap-3">
        <div className="min-w-0 flex-1"><h2 className="text-sm font-bold text-brand-900">Lagevoorraaddrempel</h2><p className="mt-1 text-[10px] text-slate-400">Standaard 10; wijziging vereist AAL2, reden en audit.</p></div>
        <label className="text-[10px] font-semibold text-slate-600">Aantal<input type="number" min={0} max={100000} value={value} onChange={(event) => setValue(event.target.value)} className="mt-1 h-9 w-24 rounded-lg border border-line px-2 text-xs" /></label>
        <label className="min-w-[220px] flex-1 text-[10px] font-semibold text-slate-600">Reden<input value={reason} onChange={(event) => setReason(event.target.value)} minLength={4} maxLength={500} required placeholder="Waarom wijzigt de drempel?" className="mt-1 h-9 w-full rounded-lg border border-line px-2 text-xs" /></label>
        <button disabled={saving || reason.trim().length < 4} className="flex h-9 items-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white disabled:bg-slate-300">{saving ? <Loader2 className="size-3.5 animate-spin" /> : <Save className="size-3.5" />} Opslaan</button>
      </div>
    </form>
  );
}
