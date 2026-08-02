import { createHash } from "node:crypto";
import type {
  DynamicImportMappingWorkspace,
  ImportMapping,
  StagedImportPayload,
} from "@/lib/import-contract";
import { parseCsvBytes, type ParsedCsv } from "@/server/imports/csv-parser";
import { decryptImportPayload } from "@/server/imports/staging-crypto";

const unsafeValueFormat =
  /[\p{Cc}\p{Cf}\u034F\u115F\u1160\u17B4\u17B5\u180B-\u180F\u3164\uFE00-\uFE0F\uFFA0]/u;
const formulaPrefix = /^[=+\-@\t\r]/u;

export function normalizeImportHeader(value: string) {
  return value.normalize("NFKC").trim().replace(/\s+/gu, " ").toLocaleLowerCase("nl-NL");
}

export function normalizeImportSize(value: string) {
  return value.normalize("NFKC").trim().replace(/\s+/gu, " ").toLocaleUpperCase("nl-NL");
}

export function sha256Hex(value: string | Uint8Array) {
  return createHash("sha256").update(value).digest("hex");
}

export function importHeaderHash(headers: readonly string[]) {
  return sha256Hex(JSON.stringify(headers));
}

export function openStagedCsv(payload: StagedImportPayload, encryptionKey: string) {
  const bytes = decryptImportPayload(
    {
      ciphertext: payload.ciphertext,
      nonce: payload.nonce,
      keyVersion: payload.keyVersion,
      keyFingerprint: payload.keyFingerprint,
    },
    encryptionKey,
    payload.batchId,
    payload.checksum,
  );
  const parsed = parseCsvBytes(bytes);
  if (
    parsed.delimiter !== payload.delimiter
    || parsed.records.length !== payload.rowCount
    || parsed.headers.length !== payload.columnCount
  ) {
    throw new Error("DYNAMIC_IMPORT_PAYLOAD_METADATA_MISMATCH");
  }
  return parsed;
}

export function selectedMappingForStorage(mapping: ImportMapping) {
  return mapping.entries.flatMap((entry) => (
    entry.target.kind === "ignore"
      ? []
      : [{
        columnIndex: entry.columnIndex,
        sourceHeaderHash: sha256Hex(entry.sourceHeader),
        target: entry.target,
      }]
  ));
}

export function assertMappingHeaders(mapping: ImportMapping, parsed: ParsedCsv) {
  for (const entry of mapping.entries) {
    if (parsed.headers[entry.columnIndex] !== entry.sourceHeader) {
      throw new Error("DYNAMIC_IMPORT_HEADER_CHANGED");
    }
  }
}

type CatalogArticle = DynamicImportMappingWorkspace["articles"][number];
type Match = {
  variantId: string;
  variantLabel: string;
  matchedBy: "code" | "label" | "alias";
};

function articleMatchIndex(article: CatalogArticle) {
  const matches = new Map<string, Match | null>();
  const add = (raw: string | null, match: Match) => {
    if (!raw) return;
    const key = normalizeImportSize(raw);
    const existing = matches.get(key);
    matches.set(key, existing && existing.variantId !== match.variantId ? null : match);
  };
  for (const variant of article.variants) {
    if (variant.code) {
      add(variant.code, {
        variantId: variant.id,
        variantLabel: variant.label,
        matchedBy: "code",
      });
    }
    add(variant.label, {
      variantId: variant.id,
      variantLabel: variant.label,
      matchedBy: "label",
    });
    for (const alias of variant.aliases) {
      add(alias, {
        variantId: variant.id,
        variantLabel: variant.label,
        matchedBy: "alias",
      });
    }
  }
  return matches;
}

export function buildSizeDiagnostics(
  mapping: ImportMapping,
  parsed: ParsedCsv,
  workspace: DynamicImportMappingWorkspace,
) {
  const articles = new Map(workspace.articles.map((article) => [article.id, article]));
  return mapping.entries.flatMap((entry) => {
    if (entry.target.kind !== "product_size") return [];
    const article = articles.get(entry.target.articleId);
    if (!article || !article.importable) throw new Error("DYNAMIC_IMPORT_PRODUCT_NOT_IMPORTABLE");
    const index = articleMatchIndex(article);
    const values = new Map<string, {
      rawValue: string;
      count: number;
      outcome: "recognized" | "unknown" | "unsafe";
      variantId?: string;
      variantLabel?: string;
      matchedBy?: "code" | "label" | "alias";
    }>();
    let emptyCount = 0;
    let recognizedCount = 0;
    let unknownCount = 0;
    let unsafeCount = 0;

    for (const record of parsed.records) {
      const rawValue = record[entry.columnIndex]?.trim() ?? "";
      if (!rawValue) {
        emptyCount += 1;
        continue;
      }
      const unsafe =
        rawValue.length > 160
        || unsafeValueFormat.test(rawValue)
        || formulaPrefix.test(rawValue);
      const match = unsafe ? undefined : index.get(normalizeImportSize(rawValue));
      const outcome = unsafe ? "unsafe" : match ? "recognized" : "unknown";
      if (outcome === "recognized") recognizedCount += 1;
      else if (outcome === "unsafe") unsafeCount += 1;
      else unknownCount += 1;
      const key = `${outcome}:${rawValue}`;
      const existing = values.get(key);
      if (existing) existing.count += 1;
      else {
        values.set(key, {
          rawValue,
          count: 1,
          outcome,
          ...(match ?? {}),
        });
      }
    }

    return [{
      columnIndex: entry.columnIndex,
      articleId: article.id,
      articleName: article.name,
      totalCount: parsed.records.length,
      emptyCount,
      recognizedCount,
      unknownCount,
      unsafeCount,
      values: [...values.values()].sort((left, right) => (
        left.rawValue.localeCompare(right.rawValue, "nl-NL")
      )),
    }];
  });
}

export function normalizePresetEntries(
  entries: Array<{
    sourceHeaderKey: string;
    target:
      | { kind: "member_field"; field: string }
      | { kind: "product_size"; articleId: string };
  }>,
) {
  const headers = new Set<string>();
  const fields = new Set<string>();
  const articles = new Set<string>();
  return entries.map((entry) => {
    const sourceHeaderKey = normalizeImportHeader(entry.sourceHeaderKey);
    if (!sourceHeaderKey || headers.has(sourceHeaderKey)) {
      throw new Error("DYNAMIC_IMPORT_PRESET_INVALID");
    }
    headers.add(sourceHeaderKey);
    if (entry.target.kind === "member_field") {
      if (fields.has(entry.target.field)) throw new Error("DYNAMIC_IMPORT_PRESET_INVALID");
      fields.add(entry.target.field);
    } else {
      if (articles.has(entry.target.articleId)) throw new Error("DYNAMIC_IMPORT_PRESET_INVALID");
      articles.add(entry.target.articleId);
    }
    return { sourceHeaderKey, target: entry.target };
  });
}
