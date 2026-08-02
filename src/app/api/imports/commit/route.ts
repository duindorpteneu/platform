import { createHash } from "node:crypto";
import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import { requireStaffRole } from "@/server/auth/staff";
import { getSupabaseServerClient } from "@/server/supabase/server";
import {
  normalizeSportlinkFileName,
  previewSportlinkImport,
  sportlinkUploadMetadata,
  toSportlinkDatabaseRows,
} from "@/server/imports/sportlink";
import { BODY_POLICIES, guardBrowserMutation, readTextRequest } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.sportlinkCsv });
  if (guarded) return guarded;
  try {
    if (getServerEnv().DYNAMIC_IMPORT_ENABLED === "true") {
      return NextResponse.json(
        { error: "De oude import is uitgeschakeld. Gebruik de dynamische import." },
        { status: 410, headers: { "Cache-Control": "private, no-store, max-age=0" } },
      );
    }
    await requireStaffRole(["beheerder", "kledingcommissie"]);
    const supabase = await getSupabaseServerClient();
    if (!supabase) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });

    const body = await readTextRequest(request, BODY_POLICIES.sportlinkCsv);
    if (!body.ok) return body.response;
    const file = sportlinkUploadMetadata(request.headers, new TextEncoder().encode(body.data).byteLength);
    const input = body.data;
    const preview = previewSportlinkImport(input);
    if (preview.issues.length > 0 || preview.members.length === 0) {
      return NextResponse.json({ error: "De import bevat ongeldige rijen en is niet opgeslagen.", issues: preview.issues, summary: preview.summary }, { status: 422 });
    }

    const checksum = createHash("sha256").update(Buffer.from(input, "utf8")).digest("hex");
    const { data, error } = await supabase.schema("app").rpc("commit_sportlink_import", {
      p_file_name: normalizeSportlinkFileName(file.name),
      p_checksum: checksum,
      p_mapping: { delimiter: preview.delimiter, source: "Sportlink CSV", columns: preview.mapping, fallbacks: preview.warnings },
      p_members: toSportlinkDatabaseRows(preview.members),
    });
    if (error) {
      if (error.message?.includes("LEGACY_IMPORT_DISABLED")) {
        return NextResponse.json(
          { error: "De oude import is uitgeschakeld. Gebruik de dynamische import." },
          { status: 410, headers: { "Cache-Control": "private, no-store, max-age=0" } },
        );
      }
      if (error.code === "42501") return NextResponse.json({ error: "Geen toegang tot deze import." }, { status: 403 });
      return NextResponse.json({ error: "De import kon niet transactioneel worden opgeslagen." }, { status: 500 });
    }
    return NextResponse.json({ ...data, checksum, summary: preview.summary }, { status: 201 });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot deze import." }, { status: 403 });
    if (error instanceof Error && error.message.startsWith("CSV_")) return NextResponse.json({ error: "Het CSV-bestand kan niet veilig worden gelezen." }, { status: 400 });
    return NextResponse.json({ error: "De import kon niet worden verwerkt." }, { status: 500 });
  }
}
