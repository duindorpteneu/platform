import { createHash, randomUUID } from "node:crypto";
import { NextResponse } from "next/server";
import { z } from "zod";
import {
  dynamicImportDryRunMutationSchema,
  dynamicImportDryRunSchema,
  dynamicImportDryRunStartResponseSchema,
  dynamicImportRowOutcomeSchema,
} from "@/lib/import-contract";
import { getServerEnv } from "@/lib/env";
import { requireStaffRole } from "@/server/auth/staff";
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
const querySchema = z.object({
  runId: z.string().uuid(),
  outcome: dynamicImportRowOutcomeSchema.optional(),
  offset: z.coerce.number().int().min(0).max(10_000).default(0),
  limit: z.coerce.number().int().min(1).max(100).default(100),
}).strict();

function requestHash(input: z.infer<typeof dynamicImportDryRunMutationSchema>) {
  return createHash("sha256")
    .update(JSON.stringify({
      batchId: input.batchId,
      mappingRevision: input.mappingRevision,
      clientRequestId: input.clientRequestId,
    }))
    .digest("hex");
}

function errorResponse(error: unknown) {
  const code = error instanceof Error ? error.message : "";
  if (code === "STAFF_AUTHORIZATION_REQUIRED") {
    return NextResponse.json(
      { error: "Alleen een beheerder met MFA kan een import-dry-run starten of bekijken." },
      { status: 403, headers: privateHeaders },
    );
  }
  if (code === "DYNAMIC_IMPORT_DISABLED") {
    return NextResponse.json(
      { error: "De dynamische import is veilig gepauzeerd." },
      { status: 503, headers: privateHeaders },
    );
  }
  if (
    code === "DYNAMIC_IMPORT_REVISION_CHANGED"
    || code === "DYNAMIC_IMPORT_CATALOG_CHANGED"
  ) {
    return NextResponse.json(
      { error: "De mapping of productcatalogus is gewijzigd. Valideer de kolommen opnieuw." },
      { status: 409, headers: privateHeaders },
    );
  }
  if (code === "DYNAMIC_IMPORT_IDEMPOTENCY_CONFLICT") {
    return NextResponse.json(
      { error: "Deze idempotentiesleutel hoort al bij een andere dry-run." },
      { status: 409, headers: privateHeaders },
    );
  }
  if (
    code === "DYNAMIC_IMPORT_UPLOAD_NOT_AVAILABLE"
    || code === "DYNAMIC_IMPORT_DRY_RUN_NOT_FOUND"
  ) {
    return NextResponse.json(
      { error: "Deze import is verlopen of niet meer beschikbaar." },
      { status: 404, headers: privateHeaders },
    );
  }
  return NextResponse.json(
    { error: "De import-dry-run kon niet veilig worden verwerkt." },
    { status: 500, headers: privateHeaders },
  );
}

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonStandard });
  if (guarded) return guarded;
  try {
    const body = await readJsonRequest(request, BODY_POLICIES.jsonStandard);
    if (!body.ok) return body.response;
    const input = dynamicImportDryRunMutationSchema.safeParse(body.data);
    if (!input.success) {
      return NextResponse.json(
        { error: "De dry-runopdracht is ongeldig." },
        { status: 400, headers: privateHeaders },
      );
    }
    await requireStaffRole(["beheerder"]);
    if (getServerEnv().DYNAMIC_IMPORT_ENABLED !== "true") {
      throw new Error("DYNAMIC_IMPORT_DISABLED");
    }
    const supabase = await getSupabaseServerClient();
    if (!supabase) throw new Error("DYNAMIC_IMPORT_DATABASE_UNAVAILABLE");
    const { data, error } = await supabase.schema("app").rpc(
      "begin_dynamic_import_dry_run",
      {
        p_run_id: randomUUID(),
        p_batch_id: input.data.batchId,
        p_mapping_revision: input.data.mappingRevision,
        p_client_request_id: input.data.clientRequestId,
        p_request_hash: requestHash(input.data),
        p_correlation_id: normalizeCorrelationId(request.headers.get("x-correlation-id")),
      },
    );
    if (error) {
      if (error.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
      if (error.code === "P0002") throw new Error("DYNAMIC_IMPORT_UPLOAD_NOT_AVAILABLE");
      if (error.code === "23505") throw new Error("DYNAMIC_IMPORT_IDEMPOTENCY_CONFLICT");
      if (error.code === "40001") {
        if (error.message?.includes("CATALOG")) {
          throw new Error("DYNAMIC_IMPORT_CATALOG_CHANGED");
        }
        throw new Error("DYNAMIC_IMPORT_REVISION_CHANGED");
      }
      if (error.message?.includes("DYNAMIC_IMPORT_DISABLED")) {
        throw new Error("DYNAMIC_IMPORT_DISABLED");
      }
      throw new Error("DYNAMIC_IMPORT_DRY_RUN_START_FAILED");
    }
    const parsed = dynamicImportDryRunStartResponseSchema.safeParse(data);
    if (!parsed.success) throw new Error("DYNAMIC_IMPORT_DRY_RUN_RESPONSE_INVALID");
    return NextResponse.json(parsed.data, {
      status: parsed.data.reused ? 200 : 202,
      headers: privateHeaders,
    });
  } catch (error) {
    return errorResponse(error);
  }
}

export async function GET(request: Request) {
  try {
    await requireStaffRole(["beheerder"]);
    const url = new URL(request.url);
    const input = querySchema.safeParse({
      runId: url.searchParams.get("runId"),
      outcome: url.searchParams.get("outcome") || undefined,
      offset: url.searchParams.get("offset") ?? undefined,
      limit: url.searchParams.get("limit") ?? undefined,
    });
    if (!input.success) {
      return NextResponse.json(
        { error: "De dry-runquery is ongeldig." },
        { status: 400, headers: privateHeaders },
      );
    }
    const supabase = await getSupabaseServerClient();
    if (!supabase) throw new Error("DYNAMIC_IMPORT_DATABASE_UNAVAILABLE");
    const { data, error } = await supabase.schema("app").rpc(
      "get_dynamic_import_dry_run",
      {
        p_run_id: input.data.runId,
        p_outcome: input.data.outcome ?? null,
        p_offset: input.data.offset,
        p_limit: input.data.limit,
      },
    );
    if (error) {
      if (error.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
      if (error.code === "P0002") throw new Error("DYNAMIC_IMPORT_DRY_RUN_NOT_FOUND");
      throw new Error("DYNAMIC_IMPORT_DRY_RUN_QUERY_FAILED");
    }
    const parsed = dynamicImportDryRunSchema.safeParse(data);
    if (!parsed.success) throw new Error("DYNAMIC_IMPORT_DRY_RUN_RESPONSE_INVALID");
    return NextResponse.json(parsed.data, { headers: privateHeaders });
  } catch (error) {
    return errorResponse(error);
  }
}
