import { createHash, randomUUID } from "node:crypto";
import { NextResponse } from "next/server";
import { z } from "zod";
import { getServerEnv } from "@/lib/env";
import { dynamicImportUploadResponseSchema } from "@/lib/import-contract";
import { requireStaffRole } from "@/server/auth/staff";
import {
  inspectCsvColumns,
  parseCsvBytes,
} from "@/server/imports/csv-parser";
import { encryptImportPayload } from "@/server/imports/staging-crypto";
import {
  normalizeSportlinkFileName,
  sportlinkUploadMetadata,
} from "@/server/imports/sportlink";
import { normalizeCorrelationId } from "@/server/security/correlation";
import { handleEdgeBodyProbe } from "@/server/security/edge-body-probe";
import {
  BODY_POLICIES,
  guardBrowserMutation,
  readBodyRequest,
} from "@/server/security/route-guard";
import { getSupabaseServerClient } from "@/server/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const uuid = z.string().uuid();
const privateHeaders = { "Cache-Control": "private, no-store, max-age=0" };

function importError(error: unknown) {
  if (!(error instanceof Error)) {
    return NextResponse.json({ error: "De upload kon niet veilig worden klaargezet." }, { status: 500, headers: privateHeaders });
  }
  if (error.message === "STAFF_AUTHORIZATION_REQUIRED") {
    return NextResponse.json({ error: "Alleen een beheerder kan leden importeren." }, { status: 403, headers: privateHeaders });
  }
  if (error.message === "DYNAMIC_IMPORT_DISABLED") {
    return NextResponse.json({ error: "De dynamische import is in deze omgeving nog niet geactiveerd." }, { status: 503, headers: privateHeaders });
  }
  if (error.message === "DYNAMIC_IMPORT_IDEMPOTENCY_CONFLICT") {
    return NextResponse.json({ error: "Deze herhaalsleutel hoort al bij een ander bestand." }, { status: 409, headers: privateHeaders });
  }
  if (error.message.startsWith("CSV_")) {
    return NextResponse.json({ error: "Het CSV-bestand voldoet niet aan de veilige importgrenzen.", code: error.message.toLowerCase() }, { status: 400, headers: privateHeaders });
  }
  return NextResponse.json({ error: "De upload kon niet veilig worden klaargezet." }, { status: 500, headers: privateHeaders });
}

export async function POST(request: Request) {
  const edgeProbe = await handleEdgeBodyProbe(request, "sportlink-import");
  if (edgeProbe) return edgeProbe;
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.sportlinkCsv });
  if (guarded) return guarded;
  try {
    const staff = await requireStaffRole(["beheerder"]);
    const env = getServerEnv();
    if (env.DYNAMIC_IMPORT_ENABLED !== "true" || !env.IMPORT_STAGING_ENCRYPTION_KEY) {
      throw new Error("DYNAMIC_IMPORT_DISABLED");
    }
    const clientRequestId = uuid.safeParse(request.headers.get("x-duindorp-idempotency-key"));
    if (!clientRequestId.success) {
      return NextResponse.json({ error: "Een geldige herhaalsleutel ontbreekt." }, { status: 400, headers: privateHeaders });
    }
    const body = await readBodyRequest(request, BODY_POLICIES.sportlinkCsv);
    if (!body.ok) return body.response;
    const file = sportlinkUploadMetadata(request.headers, body.data.byteLength);
    const parsed = parseCsvBytes(body.data);
    const checksum = createHash("sha256").update(body.data).digest("hex");
    const batchId = randomUUID();
    const encrypted = encryptImportPayload(
      body.data,
      env.IMPORT_STAGING_ENCRYPTION_KEY,
      batchId,
      checksum,
    );
    const supabase = await getSupabaseServerClient();
    if (!supabase) throw new Error("DYNAMIC_IMPORT_DATABASE_UNAVAILABLE");
    if (!staff.activeSeason) throw new Error("ACTIVE_SEASON_REQUIRED");
    const { data, error } = await supabase.schema("app").rpc("create_dynamic_import_upload", {
      p_batch_id: batchId,
      p_client_request_id: clientRequestId.data,
      p_season_id: staff.activeSeason.id,
      p_file_name: normalizeSportlinkFileName(file.name),
      p_checksum: checksum,
      p_delimiter: parsed.delimiter,
      p_byte_count: body.data.byteLength,
      p_row_count: parsed.records.length,
      p_column_count: parsed.headers.length,
      p_ciphertext_base64: encrypted.ciphertext,
      p_nonce_base64: encrypted.nonce,
      p_key_version: encrypted.keyVersion,
      p_key_fingerprint: encrypted.keyFingerprint,
      p_retention_hours: env.IMPORT_RAW_RETENTION_HOURS,
      p_correlation_id: normalizeCorrelationId(request.headers.get("x-correlation-id")),
    });
    if (error) {
      if (error.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
      if (error.code === "23505") throw new Error("DYNAMIC_IMPORT_IDEMPOTENCY_CONFLICT");
      if (error.message?.includes("DYNAMIC_IMPORT_DISABLED")) throw new Error("DYNAMIC_IMPORT_DISABLED");
      throw new Error("DYNAMIC_IMPORT_UPLOAD_FAILED");
    }
    const response = dynamicImportUploadResponseSchema.safeParse({
      ...data,
      diagnosis: {
        fileName: normalizeSportlinkFileName(file.name),
        encoding: "UTF-8",
        delimiter: parsed.delimiter,
        byteCount: body.data.byteLength,
        rowCount: parsed.records.length,
        columnCount: parsed.headers.length,
        rowShapeIssues: parsed.rowShapeIssues,
      },
      columns: inspectCsvColumns(parsed),
    });
    if (!response.success) throw new Error("DYNAMIC_IMPORT_UPLOAD_RESPONSE_INVALID");
    return NextResponse.json(response.data, {
      status: response.data.reused ? 200 : 201,
      headers: privateHeaders,
    });
  } catch (error) {
    return importError(error);
  }
}
