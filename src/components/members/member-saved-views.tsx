"use client";

import { AlertTriangle, Bookmark, Loader2, Save, Trash2 } from "lucide-react";
import { useRouter } from "next/navigation";
import { useMemo, useState } from "react";
import {
  applyMemberSavedViewResponseSchema,
  deleteMemberSavedViewResponseSchema,
  memberSavedViewSchema,
  type MemberSavedViewFilters,
  type MemberSavedViewsResponse,
} from "@/lib/member-overview-contract";

type Busy = "apply" | "save" | "delete" | null;

function requestHeaders() {
  return {
    "Content-Type": "application/json",
    "X-Duindorp-CSRF": "same-origin",
  };
}

function memberViewHref(filters: MemberSavedViewFilters) {
  const params = new URLSearchParams();
  for (const key of [
    "team",
    "payment",
    "orderStatus",
    "articleId",
    "size",
    "lineStatus",
  ] as const) {
    const value = filters[key];
    if (value) params.set(key, value);
  }
  const query = params.toString();
  return query ? `/backoffice/leden?${query}` : "/backoffice/leden";
}

async function responseError(response: Response, fallback: string) {
  const payload: unknown = await response.json();
  return typeof payload === "object" && payload && "error" in payload
    ? String(payload.error)
    : fallback;
}

export function MemberSavedViews({
  workspace,
  currentFilters,
}: {
  workspace: MemberSavedViewsResponse;
  currentFilters: MemberSavedViewFilters;
}) {
  const router = useRouter();
  const [selectedId, setSelectedId] = useState(
    workspace.views[0]?.id ?? "",
  );
  const [name, setName] = useState("");
  const [busy, setBusy] = useState<Busy>(null);
  const [error, setError] = useState<string | null>(null);
  const selected = useMemo(
    () => workspace.views.find((view) => view.id === selectedId) ?? null,
    [selectedId, workspace.views],
  );

  async function applyView() {
    if (!selected || !selected.valid) return;
    setBusy("apply");
    setError(null);
    try {
      const response = await fetch("/api/members/saved-views/apply", {
        method: "POST",
        headers: requestHeaders(),
        body: JSON.stringify({
          viewId: selected.id,
          seasonId: workspace.seasonId,
        }),
      });
      if (!response.ok) {
        throw new Error(await responseError(
          response,
          "De opgeslagen weergave kon niet worden toegepast.",
        ));
      }
      const parsed = applyMemberSavedViewResponseSchema.safeParse(
        await response.json(),
      );
      if (!parsed.success) {
        throw new Error("De opgeslagen weergave gaf een ongeldig antwoord.");
      }
      router.push(memberViewHref(parsed.data.filters));
    } catch (applyError) {
      setError(
        applyError instanceof Error
          ? applyError.message
          : "De opgeslagen weergave kon niet worden toegepast.",
      );
      router.refresh();
    } finally {
      setBusy(null);
    }
  }

  async function saveView() {
    setBusy("save");
    setError(null);
    try {
      const response = await fetch("/api/members/saved-views", {
        method: "POST",
        headers: requestHeaders(),
        body: JSON.stringify({
          viewId: null,
          seasonId: workspace.seasonId,
          name: name.trim(),
          schemaVersion: 1,
          filters: currentFilters,
        }),
      });
      if (!response.ok) {
        throw new Error(await responseError(
          response,
          "De weergave kon niet worden opgeslagen.",
        ));
      }
      const parsed = memberSavedViewSchema.safeParse(await response.json());
      if (!parsed.success) {
        throw new Error("De opgeslagen weergave gaf een ongeldig antwoord.");
      }
      setName("");
      setSelectedId(parsed.data.id);
      router.refresh();
    } catch (saveError) {
      setError(
        saveError instanceof Error
          ? saveError.message
          : "De weergave kon niet worden opgeslagen.",
      );
    } finally {
      setBusy(null);
    }
  }

  async function deleteView() {
    if (!selected) return;
    setBusy("delete");
    setError(null);
    try {
      const response = await fetch("/api/members/saved-views", {
        method: "DELETE",
        headers: requestHeaders(),
        body: JSON.stringify({
          viewId: selected.id,
          seasonId: workspace.seasonId,
        }),
      });
      if (!response.ok) {
        throw new Error(await responseError(
          response,
          "De weergave kon niet worden verwijderd.",
        ));
      }
      const parsed = deleteMemberSavedViewResponseSchema.safeParse(
        await response.json(),
      );
      if (!parsed.success) {
        throw new Error("De verwijderactie gaf een ongeldig antwoord.");
      }
      setSelectedId("");
      router.refresh();
    } catch (deleteError) {
      setError(
        deleteError instanceof Error
          ? deleteError.message
          : "De weergave kon niet worden verwijderd.",
      );
    } finally {
      setBusy(null);
    }
  }

  return (
    <section className="border-b border-line bg-white px-5 py-4" aria-label="Opgeslagen ledenweergaven">
      <div className="flex flex-col gap-3 xl:flex-row xl:items-end">
        <label className="min-w-64 flex-1 text-xs font-bold uppercase tracking-[0.08em] text-slate-500">
          Opgeslagen weergave
          <select
            value={selectedId}
            onChange={(event) => {
              setSelectedId(event.target.value);
              setError(null);
            }}
            className="mt-2 h-10 w-full rounded-lg border border-line bg-white px-3 text-xs font-normal normal-case tracking-normal text-slate-600 outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100"
          >
            <option value="">Kies een weergave</option>
            {workspace.views.map((view) => (
              <option key={view.id} value={view.id}>
                {view.name}{view.valid ? "" : " — verouderd"}
              </option>
            ))}
          </select>
        </label>
        <div className="flex gap-2">
          <button
            type="button"
            onClick={() => void applyView()}
            disabled={!selected?.valid || busy !== null}
            title={!selected?.valid && selected
              ? "Deze filters zijn verouderd en worden niet gedeeltelijk toegepast"
              : undefined}
            className="inline-flex h-10 items-center justify-center gap-2 rounded-lg border border-brand-200 bg-white px-3 text-xs font-semibold text-brand-700 hover:border-brand-500 disabled:cursor-not-allowed disabled:opacity-40"
          >
            {busy === "apply"
              ? <Loader2 className="size-3.5 animate-spin" />
              : <Bookmark className="size-3.5" />}
            Toepassen
          </button>
          <button
            type="button"
            onClick={() => void deleteView()}
            disabled={!selected || busy !== null}
            className="inline-flex size-10 items-center justify-center rounded-lg border border-line bg-white text-slate-500 hover:border-red-300 hover:text-danger disabled:cursor-not-allowed disabled:opacity-40"
            aria-label="Verwijder geselecteerde weergave"
          >
            {busy === "delete"
              ? <Loader2 className="size-3.5 animate-spin" />
              : <Trash2 className="size-3.5" />}
          </button>
        </div>
        <label className="min-w-64 flex-1 text-xs font-bold uppercase tracking-[0.08em] text-slate-500">
          Huidige filters opslaan als
          <span className="mt-2 flex gap-2">
            <input
              value={name}
              onChange={(event) => setName(event.target.value)}
              maxLength={80}
              placeholder="Bijv. JO13 · nog te betalen"
              className="h-10 min-w-0 flex-1 rounded-lg border border-line bg-white px-3 text-xs font-normal normal-case tracking-normal text-ink outline-none focus:border-brand-500 focus:ring-2 focus:ring-brand-100"
            />
            <button
              type="button"
              onClick={() => void saveView()}
              disabled={name.trim().length === 0 || busy !== null}
              className="inline-flex h-10 items-center justify-center gap-2 rounded-lg bg-brand-700 px-3 text-xs font-semibold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:opacity-40"
            >
              {busy === "save"
                ? <Loader2 className="size-3.5 animate-spin" />
                : <Save className="size-3.5" />}
              Opslaan
            </button>
          </span>
        </label>
      </div>
      <p className="mt-3 text-xs leading-5 text-slate-500">
        Zoektekst, geopende leden en paginanummer worden niet opgeslagen.
        Filters worden bij toepassen opnieuw tegen dit seizoen gevalideerd.
      </p>
      {selected && !selected.valid && (
        <p className="mt-3 flex items-start gap-2 rounded-lg border border-amber-200 bg-amber-50 p-3 text-xs leading-5 text-amber-800">
          <AlertTriangle className="mt-0.5 size-3.5 shrink-0" />
          Deze weergave verwijst naar een verwijderd of inactief team, product
          of maat. Geen enkel deel van de preset wordt toegepast.
        </p>
      )}
      {error && (
        <p role="alert" className="mt-3 text-xs font-semibold text-danger">
          {error}
        </p>
      )}
    </section>
  );
}
