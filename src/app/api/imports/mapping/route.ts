import { NextResponse } from "next/server";
import { z } from "zod";
import {
  dynamicImportMappingRequestSchema,
  dynamicImportMappingResponseSchema,
  dynamicImportMappingWorkspaceSchema,
} from "@/lib/import-contract";
import { getServerEnv } from "@/lib/env";
import { requireStaffRole } from "@/server/auth/staff";
import {
  assertMappingHeaders,
  buildSizeDiagnostics,
  importHeaderHash,
  openStagedCsv,
  selectedMappingForStorage,
} from "@/server/imports/mapping";
import { readStagedImportPayload } from "@/server/imports/workspace";
import { normalizeCorrelationId } from "@/server/security/correlation";
import {
  BODY_POLICIES,
  guardBrowserMutation,
  readJsonRequest,
} from "@/server/security/route-guard";
import { getSupabaseServerClient } from "@/server/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const privateHeaders = { "Cache-Control": "private, no-store, max-age=0" };
const querySchema = z.string().uuid();
const saveResponseSchema = dynamicImportMappingResponseSchema.omit({ sizeDiagnostics: true });

function errorResponse(error: unknown) {
  const code = error instanceof Error ? error.message : "";
  if (code === "STAFF_AUTHORIZATION_REQUIRED") {
    return NextResponse.json(
      { error: "Alleen een beheerder met MFA kan importkolommen koppelen." },
      { status: 403, headers: privateHeaders },
    );
  }
  if (code === "DYNAMIC_IMPORT_DISABLED") {
    return NextResponse.json(
      { error: "De dynamische import is veilig gepauzeerd." },
      { status: 503, headers: privateHeaders },
    );
  }
  if (code === "DYNAMIC_IMPORT_UPLOAD_NOT_AVAILABLE") {
    return NextResponse.json(
      { error: "Deze upload is verlopen of niet meer beschikbaar." },
      { status: 404, headers: privateHeaders },
    );
  }
  if (
    code === "DYNAMIC_IMPORT_REVISION_CHANGED"
    || code === "DYNAMIC_IMPORT_CATALOG_CHANGED"
    || code === "DYNAMIC_IMPORT_PRESET_CHANGED"
    || code === "DYNAMIC_IMPORT_HEADER_CHANGED"
  ) {
    return NextResponse.json(
      { error: "De upload, preset of productcatalogus is intussen gewijzigd. Controleer de koppeling opnieuw." },
      { status: 409, headers: privateHeaders },
    );
  }
  if (
    code.startsWith("IMPORT_STAGING_")
    || code === "DYNAMIC_IMPORT_PAYLOAD_METADATA_MISMATCH"
  ) {
    return NextResponse.json(
      { error: "De versleutelde upload kon niet integer worden gecontroleerd." },
      { status: 422, headers: privateHeaders },
    );
  }
  if (
    code === "DYNAMIC_IMPORT_MAPPING_INVALID"
    || code === "DYNAMIC_IMPORT_PRODUCT_NOT_IMPORTABLE"
  ) {
    return NextResponse.json(
      { error: "De kolomkoppeling is ongeldig of verwijst naar een niet-importeerbaar product." },
      { status: 422, headers: privateHeaders },
    );
  }
  return NextResponse.json(
    { error: "De kolomkoppeling kon niet veilig worden verwerkt." },
    { status: 500, headers: privateHeaders },
  );
}

async function mappingWorkspace(batchId: string) {
  const staff = await requireStaffRole(["beheerder"]);
  const env = getServerEnv();
  if (env.DYNAMIC_IMPORT_ENABLED !== "true" || !env.IMPORT_STAGING_ENCRYPTION_KEY) {
    throw new Error("DYNAMIC_IMPORT_DISABLED");
  }
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("DYNAMIC_IMPORT_DATABASE_UNAVAILABLE");
  const { data, error } = await supabase.schema("app").rpc(
    "get_dynamic_import_mapping_workspace",
    { p_batch_id: batchId },
  );
  if (error) {
    if (error.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
    if (error.code === "P0002") throw new Error("DYNAMIC_IMPORT_UPLOAD_NOT_AVAILABLE");
    if (error.message?.includes("DYNAMIC_IMPORT_DISABLED")) throw new Error("DYNAMIC_IMPORT_DISABLED");
    throw new Error("DYNAMIC_IMPORT_MAPPING_WORKSPACE_FAILED");
  }
  const parsed = dynamicImportMappingWorkspaceSchema.safeParse(data);
  if (!parsed.success) throw new Error("DYNAMIC_IMPORT_MAPPING_WORKSPACE_INVALID");
  if (!staff.activeSeason || staff.activeSeason.id !== parsed.data.seasonId) {
    throw new Error("DYNAMIC_IMPORT_UPLOAD_NOT_AVAILABLE");
  }
  return { staff, env, supabase, workspace: parsed.data };
}

export async function GET(request: Request) {
  try {
    const batchId = querySchema.safeParse(new URL(request.url).searchParams.get("batchId"));
    if (!batchId.success) {
      return NextResponse.json(
        { error: "Een geldige upload-ID ontbreekt." },
        { status: 400, headers: privateHeaders },
      );
    }
    const { workspace } = await mappingWorkspace(batchId.data);
    return NextResponse.json(workspace, { headers: privateHeaders });
  } catch (error) {
    return errorResponse(error);
  }
}

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonStandard });
  if (guarded) return guarded;
  try {
    const body = await readJsonRequest(request, BODY_POLICIES.jsonStandard);
    if (!body.ok) return body.response;
    const input = dynamicImportMappingRequestSchema.safeParse(body.data);
    if (!input.success) {
      return NextResponse.json(
        { error: "De kolomkoppeling is niet volledig of ongeldig." },
        { status: 400, headers: privateHeaders },
      );
    }
    const { staff, env, supabase, workspace } = await mappingWorkspace(input.data.batchId);
    if (
      workspace.revision !== input.data.expectedRevision
      || workspace.catalogHash !== input.data.expectedCatalogHash
    ) {
      throw new Error("DYNAMIC_IMPORT_REVISION_CHANGED");
    }
    const payload = await readStagedImportPayload({
      batchId: input.data.batchId,
      actorId: staff.userId,
      seasonId: workspace.seasonId,
      previewRevision: input.data.expectedRevision,
    });
    const parsedCsv = openStagedCsv(payload, env.IMPORT_STAGING_ENCRYPTION_KEY!);
    assertMappingHeaders(input.data.mapping, parsedCsv);
    const storedMapping = selectedMappingForStorage(input.data.mapping);
    const diagnostics = buildSizeDiagnostics(input.data.mapping, parsedCsv, workspace);
    const { data, error } = await supabase.schema("app").rpc("save_dynamic_import_mapping", {
      p_batch_id: input.data.batchId,
      p_expected_revision: input.data.expectedRevision,
      p_expected_catalog_hash: input.data.expectedCatalogHash,
      p_header_hash: importHeaderHash(parsedCsv.headers),
      p_mapping: storedMapping,
      p_policy: input.data.mapping.policy,
      p_preset_id: input.data.preset?.id ?? null,
      p_preset_revision: input.data.preset?.revision ?? null,
      p_correlation_id: normalizeCorrelationId(request.headers.get("x-correlation-id")),
    });
    if (error) {
      if (error.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
      if (error.code === "P0002") throw new Error("DYNAMIC_IMPORT_UPLOAD_NOT_AVAILABLE");
      if (error.code === "40001") {
        if (error.message?.includes("CATALOG")) throw new Error("DYNAMIC_IMPORT_CATALOG_CHANGED");
        if (error.message?.includes("PRESET")) throw new Error("DYNAMIC_IMPORT_PRESET_CHANGED");
        throw new Error("DYNAMIC_IMPORT_REVISION_CHANGED");
      }
      if (error.message?.includes("PRODUCT_NOT_IMPORTABLE")) {
        throw new Error("DYNAMIC_IMPORT_PRODUCT_NOT_IMPORTABLE");
      }
      throw new Error("DYNAMIC_IMPORT_MAPPING_SAVE_FAILED");
    }
    const saved = saveResponseSchema.safeParse(data);
    if (!saved.success) throw new Error("DYNAMIC_IMPORT_MAPPING_SAVE_INVALID");
    const response = dynamicImportMappingResponseSchema.parse({
      ...saved.data,
      sizeDiagnostics: diagnostics,
    });
    return NextResponse.json(response, {
      status: response.reused ? 200 : 201,
      headers: privateHeaders,
    });
  } catch (error) {
    return errorResponse(error);
  }
}
