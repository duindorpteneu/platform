import { NextResponse } from "next/server";
import { exportFormatSchema, exportTypeSchema } from "@/lib/export-contract";
import { createCsvExport, createExportFilename, createXlsxExport } from "@/server/exports/generate";
import { getExportPayload } from "@/server/exports/workspace";
import { z } from "zod";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const querySchema = z.object({ format: exportFormatSchema, seasonId: z.string().uuid().nullable(), filter: z.string().max(100).nullable() }).strict();

export async function GET(request: Request, context: { params: Promise<{ type: string }> }) {
  try {
    const { type: rawType } = await context.params;
    const type = exportTypeSchema.safeParse(rawType);
    const url = new URL(request.url);
    const query = querySchema.safeParse({ format: url.searchParams.get("format"), seasonId: url.searchParams.get("seasonId"), filter: url.searchParams.get("filter") });
    if (!type.success || !query.success) return NextResponse.json({ error: "Ongeldige exportselectie." }, { status: 400 });
    const payload = await getExportPayload(type.data, query.data.seasonId, query.data.filter ?? "all");
    const filename = createExportFilename(payload, query.data.format);
    const body = query.data.format === "csv" ? createCsvExport(payload) : await createXlsxExport(payload);
    return new NextResponse(body, { headers: {
      "Cache-Control": "private, no-store",
      "Content-Disposition": `attachment; filename="${filename}"`,
      "Content-Type": query.data.format === "csv" ? "text/csv; charset=utf-8" : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "X-Content-Type-Options": "nosniff",
    } });
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot exports." }, { status: 403 });
    return NextResponse.json({ error: "De export kon niet veilig worden gegenereerd." }, { status: 503 });
  }
}
