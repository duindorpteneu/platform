"use client";

import {
  AlertTriangle,
  CheckCircle2,
  Loader2,
  LockKeyhole,
  Pause,
  ShieldCheck,
} from "lucide-react";
import { useState } from "react";
import type {
  ReleaseControlWorkspace,
} from "@/lib/release-control-contract";

type ControlKey =
  | "member_seasons_v2"
  | "package_orders_v2"
  | "dynamic_import_v2"
  | "parent_access_grants_v2"
  | "allocation_qr_v2";

const labels: Record<ControlKey, { title: string; text: string }> = {
  member_seasons_v2: {
    title: "Lid-seizoenen",
    text: "Expliciete seizoenidentiteit en gereconcilieerde historische koppelingen.",
  },
  package_orders_v2: {
    title: "Kledingpakketten",
    text: "Pakketrevisies, snapshots, pakketprijs en pakketbrede maten.",
  },
  dynamic_import_v2: {
    title: "Dynamische Sportlink-import",
    text: "Kolommapping, dry-run, DOB en beschermde maatprovenance.",
  },
  parent_access_grants_v2: {
    title: "Selectieve oudertoegang",
    text: "Beheerdergestuurde grants per kind en seizoen.",
  },
  allocation_qr_v2: {
    title: "Allocatiegebonden QR en scanner-PWA",
    text: "QR pas na betaling én harde reservering; uitgifte via veilige exchange.",
  },
};

function controls(workspace: ReleaseControlWorkspace) {
  return [
    {
      key: "member_seasons_v2" as const,
      ...workspace.base.memberSeasons,
      revision: workspace.base.revision,
    },
    {
      key: "package_orders_v2" as const,
      ...workspace.base.packageOrders,
      revision: workspace.base.revision,
    },
    {
      key: "dynamic_import_v2" as const,
      ...workspace.base.dynamicImport,
      revision: workspace.base.revision,
    },
    {
      key: "parent_access_grants_v2" as const,
      enabled: workspace.parentAccess.enabled,
      ready: workspace.parentAccess.ready,
      blockerCount:
        workspace.parentAccess.unresolvedGrantCount
        + workspace.parentAccess.unresolvedLegacyLinkCount,
      revision: workspace.parentAccess.revision,
    },
    {
      key: "allocation_qr_v2" as const,
      enabled: workspace.allocationQr.enabled,
      ready: workspace.allocationQr.ready,
      blockerCount: workspace.allocationQr.ready ? 0 : 1,
      revision: workspace.allocationQr.revision,
    },
  ];
}

export function ReleaseControlPanel({
  workspace,
}: {
  workspace: ReleaseControlWorkspace;
}) {
  const [current, setCurrent] = useState(workspace);
  const [selected, setSelected] = useState<ControlKey | null>(null);
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);

  async function change(
    key: ControlKey,
    action: "activate" | "pause",
  ) {
    const target = controls(current).find((item) => item.key === key);
    if (!target) return;
    setBusy(true);
    setNotice(null);
    try {
      const response = await fetch("/api/settings/release-controls", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Duindorp-CSRF": "same-origin",
        },
        body: JSON.stringify({
          action,
          key,
          expectedRevision: target.revision,
          reason,
        }),
      });
      const payload = await response.json() as {
        controls?: ReleaseControlWorkspace;
        error?: string;
      };
      if (!response.ok || !payload.controls) {
        throw new Error(payload.error ?? "Procespoort wijzigen mislukt.");
      }
      setCurrent(payload.controls);
      setSelected(null);
      setReason("");
      setNotice(
        action === "activate"
          ? "Procespoort is geactiveerd en geaudit."
          : "Import is operationeel gepauzeerd; de cutover blijft intact.",
      );
    } catch (error) {
      setNotice(
        error instanceof Error
          ? error.message
          : "Procespoort wijzigen mislukt.",
      );
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="rounded-xl border border-line bg-white p-6 shadow-card">
      <div className="border-b border-line pb-5">
        <p className="text-xs font-bold uppercase tracking-[0.12em] text-brand-500">
          Gecontroleerde cutovers
        </p>
        <h2 className="mt-1 text-lg font-bold text-brand-900">
          Phase-B-procespoorten
        </h2>
        <p className="mt-1 text-xs leading-5 text-slate-500">
          Activatie vereist MFA, een actuele preflight en een reden. QR,
          oudertoegang en import kunnen niet via een generieke schakelaar worden
          omzeild.
        </p>
      </div>
      {notice && (
        <div
          role="status"
          className="mt-4 rounded-lg border border-brand-100 bg-brand-50 p-3 text-xs text-brand-900"
        >
          {notice}
        </div>
      )}
      <div className="mt-5 space-y-3">
        {controls(current).map((control) => {
          const copy = labels[control.key];
          return (
            <div
              key={control.key}
              className="rounded-xl border border-line p-4"
            >
              <div className="flex items-start gap-3">
                <span className={`mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-lg ${
                  control.enabled
                    ? "bg-emerald-50 text-success"
                    : control.ready
                      ? "bg-brand-50 text-brand-700"
                      : "bg-amber-50 text-amber-700"
                }`}>
                  {control.enabled
                    ? <CheckCircle2 className="size-4" />
                    : control.ready
                      ? <ShieldCheck className="size-4" />
                      : <AlertTriangle className="size-4" />}
                </span>
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <h3 className="text-xs font-bold text-brand-900">
                      {copy.title}
                    </h3>
                    <span className="rounded-full bg-slate-100 px-2 py-0.5 text-xs font-bold uppercase text-slate-500">
                      {control.enabled
                        ? "Actief"
                        : control.ready
                          ? "Gereed"
                          : `${control.blockerCount} blokkade(n)`}
                    </span>
                  </div>
                  <p className="mt-1 text-xs leading-5 text-slate-500">
                    {copy.text}
                  </p>
                </div>
              </div>
              {selected === control.key ? (
                <div className="mt-4 rounded-lg bg-slate-50 p-3">
                  <label className="text-xs font-semibold text-ink">
                    Reden
                    <textarea
                      value={reason}
                      onChange={(event) => setReason(event.target.value)}
                      rows={2}
                      maxLength={500}
                      className="mt-2 w-full rounded-lg border border-line bg-white p-3 text-xs outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100"
                    />
                  </label>
                  <div className="mt-3 flex justify-end gap-2">
                    <button
                      type="button"
                      onClick={() => {
                        setSelected(null);
                        setReason("");
                      }}
                      className="h-9 rounded-lg border border-line px-3 text-xs font-bold text-slate-600"
                    >
                      Annuleren
                    </button>
                    <button
                      type="button"
                      disabled={busy || reason.trim().length < 4}
                      onClick={() => void change(
                        control.key,
                        control.enabled ? "pause" : "activate",
                      )}
                      className="inline-flex h-9 items-center gap-2 rounded-lg bg-brand-700 px-3 text-xs font-bold text-white disabled:opacity-50"
                    >
                      {busy
                        ? <Loader2 className="size-3.5 animate-spin" />
                        : control.enabled
                          ? <Pause className="size-3.5" />
                          : <LockKeyhole className="size-3.5" />}
                      Bevestigen
                    </button>
                  </div>
                </div>
              ) : (
                <div className="mt-3 flex justify-end">
                  {(!control.enabled
                    || control.key === "dynamic_import_v2") && (
                    <button
                      type="button"
                      disabled={!control.enabled && !control.ready}
                      onClick={() => setSelected(control.key)}
                      className="h-9 rounded-lg border border-brand-200 px-3 text-xs font-bold text-brand-700 disabled:cursor-not-allowed disabled:border-line disabled:text-slate-500"
                    >
                      {control.enabled ? "Pauzeren" : "Activeren"}
                    </button>
                  )}
                </div>
              )}
            </div>
          );
        })}
      </div>
    </section>
  );
}
