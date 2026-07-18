import { createHash } from "node:crypto";
import { NextResponse } from "next/server";
import { requireStaffRole } from "@/server/auth/staff";
import { getSupabaseServerClient } from "@/server/supabase/server";
import { previewSportlinkImport, SPORTLINK_MAX_REQUEST_BYTES, toSportlinkDatabaseRows, validateSportlinkUpload } from "@/server/imports/sportlink";
import { guardBrowserMutation } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: { allowedContentTypes: ["multipart/form-data"], maxBytes: SPORTLINK_MAX_REQUEST_BYTES } }); if (guarded) return guarded;
  try {
    await requireStaffRole(["beheerder", "kledingcommissie"]);
    const supabase = await getSupabaseServerClient();
    if (!supabase) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });

    const formData = await request.formData();
    const file = formData.get("file");
    if (!(file instanceof File)) return NextResponse.json({ error: "CSV-bestand ontbreekt." }, { status: 400 });
    validateSportlinkUpload(file);

    const input = await file.text();
    const preview = previewSportlinkImport(input);
    if (preview.issues.length > 0 || preview.members.length === 0) {
      return NextResponse.json({ error: "De import bevat ongeldige rijen en is niet opgeslagen.", issues: preview.issues, summary: preview.summary }, { status: 422 });
    }

    const checksum = createHash("sha256").update(Buffer.from(input, "utf8")).digest("hex");
    const { data, error } = await supabase.schema("app").rpc("commit_sportlink_import", {
      p_file_name: "sportlink.csv",
      p_checksum: checksum,
      p_mapping: { delimiter: preview.delimiter, source: "Sportlink CSV", columns: preview.mapping },
      p_members: toSportlinkDatabaseRows(preview.members),
    });
    if (error) {
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
