import { createHash } from "node:crypto";
import { NextResponse } from "next/server";
import {
  dynamicImportCommitMutationSchema,
  dynamicImportCommitStartResponseSchema,
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

function requestHash(input: {
  runId: string;
  planHash: string;
  clientRequestId: string;
  confirmed: true;
}) {
  return createHash("sha256").update(JSON.stringify(input)).digest("hex");
}

function errorResponse(error: unknown) {
  const code = error instanceof Error ? error.message : "";
  if (code === "STAFF_AUTHORIZATION_REQUIRED") {
    return NextResponse.json(
      { error: "Alleen een beheerder met MFA kan een import definitief verwerken." },
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
    code === "DYNAMIC_IMPORT_PLAN_CHANGED"
    || code === "DYNAMIC_IMPORT_CATALOG_CHANGED"
  ) {
    return NextResponse.json(
      { error: "De dry-run of productcatalogus is gewijzigd. Voer een nieuwe dry-run uit." },
      { status: 409, headers: privateHeaders },
    );
  }
  if (code === "DYNAMIC_IMPORT_IDEMPOTENCY_CONFLICT") {
    return NextResponse.json(
      { error: "Deze idempotentiesleutel hoort al bij een andere importcommit." },
      { status: 409, headers: privateHeaders },
    );
  }
  if (
    code === "DYNAMIC_IMPORT_DRY_RUN_EXPIRED"
    || code === "DYNAMIC_IMPORT_DRY_RUN_NOT_FOUND"
  ) {
    return NextResponse.json(
      { error: "Deze dry-run is verlopen. Upload het bestand opnieuw." },
      { status: 410, headers: privateHeaders },
    );
  }
  return NextResponse.json(
    { error: "De importcommit kon niet veilig worden gestart." },
    { status: 500, headers: privateHeaders },
  );
}

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonStandard });
  if (guarded) return guarded;
  try {
    const body = await readJsonRequest(request, BODY_POLICIES.jsonStandard);
    if (!body.ok) return body.response;
    const input = dynamicImportCommitMutationSchema.safeParse(body.data);
    if (!input.success) {
      return NextResponse.json(
        { error: "De finale importbevestiging is ongeldig." },
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
      "authorize_dynamic_import_commit",
      {
        p_run_id: input.data.runId,
        p_plan_hash: input.data.planHash,
        p_client_request_id: input.data.clientRequestId,
        p_request_hash: requestHash(input.data),
        p_correlation_id: normalizeCorrelationId(request.headers.get("x-correlation-id")),
      },
    );
    if (error) {
      if (error.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
      if (error.code === "P0002") throw new Error("DYNAMIC_IMPORT_DRY_RUN_NOT_FOUND");
      if (error.code === "23505") throw new Error("DYNAMIC_IMPORT_IDEMPOTENCY_CONFLICT");
      if (error.code === "40001") {
        if (error.message?.includes("CATALOG")) {
          throw new Error("DYNAMIC_IMPORT_CATALOG_CHANGED");
        }
        throw new Error("DYNAMIC_IMPORT_PLAN_CHANGED");
      }
      if (error.message?.includes("EXPIRED")) {
        throw new Error("DYNAMIC_IMPORT_DRY_RUN_EXPIRED");
      }
      if (error.message?.includes("DISABLED")) {
        throw new Error("DYNAMIC_IMPORT_DISABLED");
      }
      throw new Error("DYNAMIC_IMPORT_COMMIT_START_FAILED");
    }
    const parsed = dynamicImportCommitStartResponseSchema.safeParse(data);
    if (!parsed.success) throw new Error("DYNAMIC_IMPORT_COMMIT_RESPONSE_INVALID");
    return NextResponse.json(parsed.data, {
      status: parsed.data.status === "committed" ? 200 : 202,
      headers: privateHeaders,
    });
  } catch (error) {
    return errorResponse(error);
  }
}
