import { NextResponse } from "next/server";
import { z } from "zod";
import {
  mappingPresetMutationSchema,
  mappingPresetSchema,
} from "@/lib/import-contract";
import { getServerEnv } from "@/lib/env";
import { requireStaffRole } from "@/server/auth/staff";
import { normalizePresetEntries } from "@/server/imports/mapping";
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
const archiveResponseSchema = z.object({
  id: z.string().uuid(),
  revision: z.number().int().positive(),
  archived: z.literal(true),
}).strict();

function presetError(error: unknown) {
  const code = error instanceof Error ? error.message : "";
  if (code === "STAFF_AUTHORIZATION_REQUIRED") {
    return NextResponse.json(
      { error: "Alleen een beheerder met MFA kan importpresets beheren." },
      { status: 403, headers: privateHeaders },
    );
  }
  if (code === "DYNAMIC_IMPORT_DISABLED") {
    return NextResponse.json(
      { error: "De dynamische import is veilig gepauzeerd." },
      { status: 503, headers: privateHeaders },
    );
  }
  if (code === "DYNAMIC_IMPORT_PRESET_CHANGED" || code === "DYNAMIC_IMPORT_PRESET_NAME_EXISTS") {
    return NextResponse.json(
      { error: code.endsWith("NAME_EXISTS")
        ? "Er bestaat al een actieve preset met deze naam."
        : "De preset is intussen gewijzigd. Vernieuw de importworkspace." },
      { status: 409, headers: privateHeaders },
    );
  }
  if (code === "DYNAMIC_IMPORT_PRESET_INVALID") {
    return NextResponse.json(
      { error: "De preset bevat een ongeldige of dubbele koppeling." },
      { status: 422, headers: privateHeaders },
    );
  }
  return NextResponse.json(
    { error: "De importpreset kon niet veilig worden opgeslagen." },
    { status: 500, headers: privateHeaders },
  );
}

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonStandard });
  if (guarded) return guarded;
  try {
    await requireStaffRole(["beheerder"]);
    if (getServerEnv().DYNAMIC_IMPORT_ENABLED !== "true") {
      throw new Error("DYNAMIC_IMPORT_DISABLED");
    }
    const body = await readJsonRequest(request, BODY_POLICIES.jsonStandard);
    if (!body.ok) return body.response;
    const input = mappingPresetMutationSchema.safeParse(body.data);
    if (!input.success) {
      return NextResponse.json(
        { error: "De presetopdracht is ongeldig." },
        { status: 400, headers: privateHeaders },
      );
    }
    const supabase = await getSupabaseServerClient();
    if (!supabase) throw new Error("DYNAMIC_IMPORT_DATABASE_UNAVAILABLE");
    const correlationId = normalizeCorrelationId(request.headers.get("x-correlation-id"));
    if (input.data.action === "archive") {
      const { data, error } = await supabase.schema("app").rpc(
        "archive_dynamic_import_mapping_preset",
        {
          p_preset_id: input.data.presetId,
          p_expected_revision: input.data.expectedRevision,
          p_correlation_id: correlationId,
        },
      );
      if (error) {
        if (error.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
        if (error.code === "40001") throw new Error("DYNAMIC_IMPORT_PRESET_CHANGED");
        throw new Error("DYNAMIC_IMPORT_PRESET_ARCHIVE_FAILED");
      }
      const response = archiveResponseSchema.safeParse(data);
      if (!response.success) throw new Error("DYNAMIC_IMPORT_PRESET_RESPONSE_INVALID");
      return NextResponse.json(response.data, { headers: privateHeaders });
    }

    const entries = normalizePresetEntries(input.data.entries);
    const { data, error } = await supabase.schema("app").rpc(
      "save_dynamic_import_mapping_preset",
      {
        p_preset_id: input.data.presetId ?? null,
        p_expected_revision: input.data.expectedRevision ?? null,
        p_name: input.data.name,
        p_entries: entries,
        p_correlation_id: correlationId,
      },
    );
    if (error) {
      if (error.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
      if (error.code === "40001") throw new Error("DYNAMIC_IMPORT_PRESET_CHANGED");
      if (error.code === "23505") throw new Error("DYNAMIC_IMPORT_PRESET_NAME_EXISTS");
      if (error.code === "22023") throw new Error("DYNAMIC_IMPORT_PRESET_INVALID");
      throw new Error("DYNAMIC_IMPORT_PRESET_SAVE_FAILED");
    }
    const response = mappingPresetSchema.safeParse(data);
    if (!response.success) throw new Error("DYNAMIC_IMPORT_PRESET_RESPONSE_INVALID");
    return NextResponse.json(response.data, {
      status: input.data.presetId ? 200 : 201,
      headers: privateHeaders,
    });
  } catch (error) {
    return presetError(error);
  }
}
