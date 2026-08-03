import { randomUUID } from "node:crypto";
import { NextResponse } from "next/server";
import { z } from "zod";
import { hasInternalBearer } from "@/server/operations/internal-auth";
import { finishOperationRun, startOperationRun } from "@/server/operations/run-ledger";
import { readEmptyRequest } from "@/server/security/route-guard";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

const resultSchema = z.object({
  processed: z.number().int().nonnegative(),
  failed: z.number().int().nonnegative(),
  disabled: z.boolean(),
}).strict();

export async function POST(request: Request) {
  if (!hasInternalBearer(request)) {
    return NextResponse.json({ error: "Geen toegang tot de voorraadworker." }, { status: 401 });
  }
  const empty = await readEmptyRequest(request);
  if (!empty.ok) return empty.response;
  const admin = getSupabaseAdminClient();
  if (!admin) return NextResponse.json({ error: "Voorraadworker tijdelijk niet beschikbaar." }, { status: 503 });

  const runId = randomUUID();
  if (!await startOperationRun(admin, "inventory_allocator", runId)) {
    return NextResponse.json({ error: "Voorraadworker kon niet worden gemonitord." }, { status: 503 });
  }
  const { data, error } = await admin.schema("app").rpc("process_inventory_allocation_queue", { p_limit: 50 });
  const parsed = resultSchema.safeParse(data);
  if (error || !parsed.success) {
    await finishOperationRun(admin, "inventory_allocator", runId, "failed", 0, "allocation_queue_failed");
    return NextResponse.json({ error: "Voorraadwachtrij kon niet veilig worden verwerkt." }, { status: 503 });
  }
  const status = parsed.data.failed > 0 ? "failed" : parsed.data.disabled ? "paused" : "succeeded";
  if (!await finishOperationRun(
    admin,
    "inventory_allocator",
    runId,
    status,
    parsed.data.processed,
    parsed.data.failed > 0 ? "allocation_job_failed" : null,
  )) {
    return NextResponse.json({ error: "Voorraadworkerresultaat kon niet worden gemonitord." }, { status: 503 });
  }
  return NextResponse.json({
    status,
    processed: parsed.data.processed,
    failed: parsed.data.failed,
  }, { status: parsed.data.failed > 0 ? 503 : 200 });
}
