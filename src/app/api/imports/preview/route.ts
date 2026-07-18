import { NextResponse } from "next/server";
import { requireStaffRole } from "@/server/auth/staff";
import { previewSportlinkImport, SPORTLINK_MAX_BYTES } from "@/server/imports/sportlink";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  try {
    await requireStaffRole(["beheerder", "kledingcommissie"]);
    const formData = await request.formData();
    const file = formData.get("file");
    if (!(file instanceof File)) {
      return NextResponse.json({ error: "CSV-bestand ontbreekt." }, { status: 400 });
    }
    if (file.size > SPORTLINK_MAX_BYTES) {
      return NextResponse.json({ error: "Het CSV-bestand is groter dan 10 MB." }, { status: 413 });
    }
    const preview = previewSportlinkImport(await file.text());
    return NextResponse.json(preview, { status: 200 });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") {
      return NextResponse.json({ error: "Geen toegang tot deze import." }, { status: 403 });
    }
    if (error instanceof Error && error.message.startsWith("CSV_")) {
      return NextResponse.json({ error: "Het CSV-bestand kan niet veilig worden gelezen." }, { status: 400 });
    }
    return NextResponse.json({ error: "De import-preview kon niet worden gemaakt." }, { status: 500 });
  }
}
