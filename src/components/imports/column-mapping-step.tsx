"use client";

import {
  AlertTriangle,
  CheckCircle2,
  Loader2,
  Save,
} from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import {
  dynamicImportMappingResponseSchema,
  dynamicImportMappingWorkspaceSchema,
  IMPORT_POLICY,
  mappingPresetSchema,
  type DynamicImportMappingResponse,
  type DynamicImportMappingWorkspace,
  type DynamicImportUploadResponse,
  type ImportMappingTarget,
  type MappingPreset,
} from "@/lib/import-contract";

const standardFields = [
  "external_member_id",
  "first_name",
  "insertion",
  "last_name",
  "email",
  "team",
  "date_of_birth",
  "gender",
  "active_for_season",
] as const;
type ImportField = (typeof standardFields)[number];

const fieldLabels: Record<ImportField, string> = {
  external_member_id: "Sportlink-relatienummer",
  first_name: "Voornaam",
  insertion: "Tussenvoegsel",
  last_name: "Achternaam",
  email: "E-mailadres ouder",
  team: "Team",
  date_of_birth: "Geboortedatum",
  gender: "Geslacht",
  active_for_season: "Actief in seizoen",
};

function normalizeHeader(value: string) {
  return value.normalize("NFKC").trim().replace(/\s+/gu, " ").toLocaleLowerCase("nl-NL");
}

function suggestedTarget(header: string): ImportMappingTarget {
  const key = normalizeHeader(header).replace(/[_.-]+/gu, " ");
  const suggestions: Record<string, ImportField> = {
    relatienummer: "external_member_id",
    "relatie nummer": "external_member_id",
    "sportlink relatienummer": "external_member_id",
    voornaam: "first_name",
    tussenvoegsel: "insertion",
    achternaam: "last_name",
    email: "email",
    "e mail": "email",
    "e mailadres": "email",
    team: "team",
    geboortedatum: "date_of_birth",
    "geboorte datum": "date_of_birth",
    geslacht: "gender",
    actief: "active_for_season",
  };
  const field = suggestions[key];
  return field ? { kind: "member_field", field } : { kind: "ignore" };
}

function targetValue(target: ImportMappingTarget) {
  if (target.kind === "ignore") return "ignore";
  if (target.kind === "member_field") return `field:${target.field}`;
  return `product:${target.articleId}`;
}

function parseTarget(value: string): ImportMappingTarget {
  if (value === "ignore") return { kind: "ignore" };
  if (value.startsWith("field:")) {
    return {
      kind: "member_field",
      field: value.slice(6) as ImportField,
    };
  }
  return { kind: "product_size", articleId: value.slice(8) };
}

type Props = {
  upload: DynamicImportUploadResponse;
  onValidated: (result: DynamicImportMappingResponse | null) => void;
};

export function ColumnMappingStep({ upload, onValidated }: Props) {
  const [workspace, setWorkspace] = useState<DynamicImportMappingWorkspace | null>(null);
  const [targets, setTargets] = useState<Record<number, ImportMappingTarget>>(() => (
    Object.fromEntries(upload.columns.map((column) => [column.index, suggestedTarget(column.label)]))
  ));
  const [selectedPreset, setSelectedPreset] = useState<MappingPreset | null>(null);
  const [validation, setValidation] = useState<DynamicImportMappingResponse | null>(null);
  const [presetName, setPresetName] = useState("");
  const [ignoreOptionalConflicts, setIgnoreOptionalConflicts] = useState(false);
  const [busy, setBusy] = useState<"loading" | "validating" | "preset" | null>("loading");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    async function load() {
      try {
        const response = await fetch(`/api/imports/mapping?batchId=${encodeURIComponent(upload.batchId)}`, {
          cache: "no-store",
        });
        const body: unknown = await response.json();
        if (!response.ok) {
          const message = body && typeof body === "object" && "error" in body && typeof body.error === "string"
            ? body.error
            : "De product- en presetlijst kon niet worden geladen.";
          throw new Error(message);
        }
        const parsed = dynamicImportMappingWorkspaceSchema.safeParse(body);
        if (!parsed.success) throw new Error("De server gaf een ongeldige mappingworkspace terug.");
        if (active) setWorkspace(parsed.data);
      } catch (cause) {
        if (active) setError(cause instanceof Error ? cause.message : "De mappingworkspace kon niet worden geladen.");
      } finally {
        if (active) setBusy(null);
      }
    }
    void load();
    return () => { active = false; };
  }, [upload.batchId]);

  const selectedEntries = useMemo(() => upload.columns.map((column) => ({
    columnIndex: column.index,
    sourceHeader: column.label,
    target: targets[column.index] ?? { kind: "ignore" as const },
  })), [targets, upload.columns]);

  function updateTarget(columnIndex: number, target: ImportMappingTarget) {
    setTargets((current) => ({ ...current, [columnIndex]: target }));
    setSelectedPreset(null);
    setValidation(null);
    onValidated(null);
    setError(null);
  }

  async function validateMapping(
    nextTargets: Record<number, ImportMappingTarget> = targets,
    preset: MappingPreset | null = selectedPreset,
  ) {
    if (!workspace) return;
    setBusy("validating");
    setError(null);
    setValidation(null);
    onValidated(null);
    try {
      const response = await fetch("/api/imports/mapping", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Duindorp-CSRF": "same-origin",
        },
        body: JSON.stringify({
          batchId: upload.batchId,
          expectedRevision: workspace.revision,
          expectedCatalogHash: workspace.catalogHash,
          ignoreOptionalConflicts,
          preset: preset ? { id: preset.id, revision: preset.revision } : null,
          mapping: {
            policy: IMPORT_POLICY,
            entries: upload.columns.map((column) => ({
              columnIndex: column.index,
              sourceHeader: column.label,
              target: nextTargets[column.index] ?? { kind: "ignore" },
            })),
          },
        }),
      });
      const body: unknown = await response.json();
      if (!response.ok) {
        const message = body && typeof body === "object" && "error" in body && typeof body.error === "string"
          ? body.error
          : "De kolomkoppeling kon niet worden gevalideerd.";
        throw new Error(message);
      }
      const parsed = dynamicImportMappingResponseSchema.safeParse(body);
      if (!parsed.success) throw new Error("De server gaf een ongeldig mappingresultaat terug.");
      setValidation(parsed.data);
      setWorkspace((current) => current ? {
        ...current,
        revision: parsed.data.revision,
        catalogHash: parsed.data.catalogHash,
      } : current);
      onValidated(parsed.data);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "De kolomkoppeling kon niet worden gevalideerd.");
    } finally {
      setBusy(null);
    }
  }

  function applyPreset(presetId: string) {
    const preset = workspace?.presets.find((candidate) => candidate.id === presetId) ?? null;
    setSelectedPreset(preset);
    if (!preset) return;
    const byHeader = new Map(preset.entries.map((entry) => [entry.sourceHeaderKey, entry.target]));
    const nextTargets = Object.fromEntries(upload.columns.map((column) => [
      column.index,
      byHeader.get(normalizeHeader(column.label)) ?? { kind: "ignore" as const },
    ]));
    setTargets(nextTargets);
    setValidation(null);
    onValidated(null);
    void validateMapping(nextTargets, preset);
  }

  async function savePreset() {
    const entries = selectedEntries.flatMap((entry) => (
      entry.target.kind === "ignore"
        ? []
        : [{ sourceHeaderKey: normalizeHeader(entry.sourceHeader), target: entry.target }]
    ));
    if (!presetName.trim() || entries.length === 0) {
      setError("Geef een presetnaam op en selecteer minimaal één kolom.");
      return;
    }
    setBusy("preset");
    setError(null);
    try {
      const response = await fetch("/api/imports/presets", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Duindorp-CSRF": "same-origin",
        },
        body: JSON.stringify({
          action: "save",
          name: presetName,
          entries,
        }),
      });
      const body: unknown = await response.json();
      if (!response.ok) {
        const message = body && typeof body === "object" && "error" in body && typeof body.error === "string"
          ? body.error
          : "De preset kon niet worden opgeslagen.";
        throw new Error(message);
      }
      const parsed = mappingPresetSchema.safeParse(body);
      if (!parsed.success) throw new Error("De server gaf een ongeldig presetresultaat terug.");
      setWorkspace((current) => current ? {
        ...current,
        presets: [...current.presets.filter((item) => item.id !== parsed.data.id), parsed.data]
          .sort((left, right) => left.name.localeCompare(right.name, "nl-NL")),
      } : current);
      setSelectedPreset(parsed.data);
      setPresetName("");
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "De preset kon niet worden opgeslagen.");
    } finally {
      setBusy(null);
    }
  }

  if (busy === "loading") {
    return <div className="mt-6 flex items-center gap-2 rounded-lg bg-slate-50 p-4 text-xs text-slate-500"><Loader2 className="size-4 animate-spin" /> Producten en presets laden…</div>;
  }

  return (
    <section className="mt-6 border-t border-line pt-6" aria-labelledby="mapping-title">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <p className="text-[11px] font-semibold uppercase tracking-[0.1em] text-brand-500">Stap 2</p>
          <h2 id="mapping-title" className="mt-1 text-lg font-bold text-brand-900">Kolommen koppelen</h2>
          <p className="mt-1 text-xs leading-5 text-slate-500">Genegeerde kolommen en waarden worden niet duurzaam overgenomen.</p>
        </div>
        {workspace && workspace.presets.length > 0 && (
          <label className="min-w-52 text-[11px] font-semibold text-slate-500">
            Preset toepassen
            <select
              value={selectedPreset?.id ?? ""}
              onChange={(event) => applyPreset(event.target.value)}
              className="mt-1 h-10 w-full rounded-lg border border-line bg-white px-3 text-xs text-ink"
            >
              <option value="">Geen preset</option>
              {workspace.presets.map((preset) => <option key={preset.id} value={preset.id}>{preset.name}</option>)}
            </select>
          </label>
        )}
      </div>

      {error && <div className="mt-4 flex items-start gap-2 rounded-lg bg-red-50 p-3 text-xs text-danger" role="alert"><AlertTriangle className="mt-0.5 size-4 shrink-0" />{error}</div>}

      <div className="mt-4 space-y-3">
        {upload.columns.map((column) => {
          const target = targets[column.index] ?? { kind: "ignore" as const };
          const article = target.kind === "product_size"
            ? workspace?.articles.find((candidate) => candidate.id === target.articleId)
            : null;
          return (
            <article key={column.index} className="grid gap-3 rounded-lg border border-line p-4 lg:grid-cols-[minmax(0,1fr)_minmax(240px,0.8fr)]">
              <div className="min-w-0">
                <div className="flex flex-wrap items-center gap-2">
                  <h3 className="truncate text-xs font-bold text-ink">{column.label}</h3>
                  <span className="rounded-full bg-slate-100 px-2 py-1 text-[9px] font-semibold text-slate-500">{column.nonEmptyCount} gevuld · {column.emptyCount} leeg</span>
                </div>
                {column.uniqueValues.length > 0 && (
                  <p className="mt-2 line-clamp-2 text-[10px] leading-4 text-slate-500">
                    Voorbeelden: {column.uniqueValues.slice(0, 3).join(" · ")}
                  </p>
                )}
                {article && (
                  <p className="mt-2 text-[10px] leading-4 text-brand-700">
                    Geldige maten: {article.variants.map((variant) => variant.label).join(", ")}
                  </p>
                )}
              </div>
              <label className="text-[11px] font-semibold text-slate-500">
                Importdoel
                <select
                  value={targetValue(target)}
                  onChange={(event) => updateTarget(column.index, parseTarget(event.target.value))}
                  className="mt-1 h-10 w-full rounded-lg border border-line bg-white px-3 text-xs text-ink focus:border-brand-500 focus:outline-none focus:ring-2 focus:ring-brand-100"
                >
                  <option value="ignore">Negeren</option>
                  <optgroup label="Standaardvelden">
                    {standardFields.map((field) => <option key={field} value={`field:${field}`}>{fieldLabels[field]}</option>)}
                  </optgroup>
                  <optgroup label="Productmaat">
                    {workspace?.articles.map((candidate) => (
                      <option key={candidate.id} value={`product:${candidate.id}`} disabled={!candidate.importable}>
                        {candidate.name}{candidate.importable ? "" : " — catalogusconflict"}
                      </option>
                    ))}
                  </optgroup>
                </select>
              </label>
            </article>
          );
        })}
      </div>

      <div className="mt-4 grid gap-3 md:grid-cols-[minmax(0,1fr)_auto]">
        <input
          value={presetName}
          onChange={(event) => setPresetName(event.target.value)}
          maxLength={80}
          placeholder="Naam voor nieuwe mappingpreset"
          className="h-11 rounded-lg border border-line px-3 text-xs text-ink"
        />
        <button
          type="button"
          disabled={busy !== null}
          onClick={() => void savePreset()}
          className="inline-flex h-11 items-center justify-center gap-2 rounded-lg border border-brand-200 px-4 text-xs font-semibold text-brand-800 hover:bg-brand-50 disabled:opacity-50"
        >
          <Save className="size-4" /> Preset opslaan
        </button>
      </div>

      <label className="mt-4 flex cursor-pointer items-start gap-3 rounded-lg border border-amber-200 bg-amber-50 p-4">
        <input
          type="checkbox"
          checked={ignoreOptionalConflicts}
          onChange={(event) => {
            setIgnoreOptionalConflicts(event.target.checked);
            setValidation(null);
            onValidated(null);
          }}
          className="mt-0.5 size-4 rounded border-amber-300 text-brand-700 focus:ring-brand-500"
        />
        <span>
          <span className="block text-xs font-bold text-amber-950">Optionele problemen negeren en lid toch importeren</span>
          <span className="mt-1 block text-[11px] leading-5 text-amber-900">
            Ongeldig of onbekend team, tussenvoegsel, geslacht, actiefstatus en productmaat worden voor die rij weggelaten. Identiteitsproblemen, een ongeldige naam/e-mail/geboortedatum en dubbele leden blijven blokkeren.
          </span>
        </span>
      </label>

      <div className="mt-3 rounded-lg border border-brand-100 bg-brand-50 p-4 text-[11px] leading-5 text-brand-800">
        <strong>Herimportbeleid:</strong> geselecteerde, niet-lege gegevens van bestaande leden worden overschreven. Lege bronwaarden wissen niets; een afwijkende geboortedatum en bevestigde of vergrendelde maten worden nooit stil overschreven.
      </div>

      <button
        type="button"
        disabled={busy !== null || !workspace}
        onClick={() => void validateMapping()}
        className="mt-3 inline-flex h-11 w-full items-center justify-center gap-2 rounded-lg bg-brand-700 px-4 text-xs font-semibold text-white hover:bg-brand-900 disabled:cursor-not-allowed disabled:bg-slate-200 disabled:text-slate-400"
      >
        {busy === "validating" && <Loader2 className="size-4 animate-spin" />}
        {busy === "validating" ? "Koppeling en alle maatwaarden controleren…" : "Koppeling valideren"}
      </button>

      {validation && (
        <div className="mt-5 space-y-4" aria-live="polite">
          <div className="flex items-start gap-3 rounded-lg border border-emerald-100 bg-emerald-50 p-4">
            <CheckCircle2 className="mt-0.5 size-5 shrink-0 text-success" />
            <div><h3 className="text-sm font-bold text-emerald-950">Koppeling gevalideerd</h3><p className="mt-1 text-xs leading-5 text-emerald-900">Revisie {validation.revision}. Iedere preset en productmaat is opnieuw tegen dit bestand en seizoen gecontroleerd.</p></div>
          </div>
          {validation.sizeDiagnostics.map((diagnostic) => (
            <article key={diagnostic.articleId} className="rounded-lg border border-line p-4">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <h3 className="text-xs font-bold text-brand-900">{diagnostic.articleName}</h3>
                <span className="text-[10px] text-slate-500">{diagnostic.recognizedCount} herkend · {diagnostic.emptyCount} leeg · {diagnostic.unknownCount} onbekend · {diagnostic.unsafeCount} onveilig</span>
              </div>
              {(diagnostic.unknownCount > 0 || diagnostic.unsafeCount > 0) && (
                <div className="mt-3 flex flex-wrap gap-2">
                  {diagnostic.values.filter((value) => value.outcome !== "recognized").map((value) => (
                    <span key={`${value.outcome}:${value.rawValue}`} className={`rounded-full px-2 py-1 text-[9px] font-semibold ${value.outcome === "unsafe" ? "bg-red-50 text-danger" : "bg-amber-50 text-amber-800"}`}>
                      {value.rawValue} · {value.count}×
                    </span>
                  ))}
                </div>
              )}
            </article>
          ))}
        </div>
      )}
    </section>
  );
}
