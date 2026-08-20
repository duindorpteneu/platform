import { randomUUID } from "node:crypto";
import { NextResponse } from "next/server";
import { z } from "zod";
import {
  deriveQrLocator,
  generateQrDerivationNonce,
  hashQrLocator,
  qrKeyVersion,
  qrPepperFingerprint,
} from "@/server/qr/tokens";
import { hasInternalBearer } from "@/server/operations/internal-auth";
import { finishOperationRun, startOperationRun } from "@/server/operations/run-ledger";
import { readEmptyRequest } from "@/server/security/route-guard";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

const resultSchema = z.object({
  processed: z.number().int().nonnegative(),
  completed: z.number().int().nonnegative(),
  retryable: z.number().int().nonnegative(),
  exhausted: z.number().int().nonnegative(),
  failed: z.number().int().nonnegative(),
  disabled: z.boolean(),
}).strict();
const expiredGrantSchema = z.object({
  expired: z.number().int().nonnegative(),
}).strict();
const candidateSchema = z.object({
  candidates: z.array(z.object({
    orderId: z.string().uuid(),
    generation: z.number().int().positive(),
    hasActiveLegacy: z.boolean(),
  }).strict()).max(10),
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
  const { data: expiredGrantData, error: expiredGrantError } = await admin
    .schema("app")
    .rpc("expire_qr_scan_grants", { p_limit: 500 });
  const expiredGrants = expiredGrantSchema.safeParse(expiredGrantData);
  if (expiredGrantError || !expiredGrants.success) {
    await finishOperationRun(
      admin,
      "inventory_allocator",
      runId,
      "failed",
      0,
      "qr_grant_expiry_failed",
    );
    return NextResponse.json(
      { error: "Verlopen QR-scanbevoegdheden konden niet veilig worden gesloten." },
      { status: 503 },
    );
  }
  const { data, error } = await admin.schema("app").rpc("process_inventory_allocation_queue", { p_limit: 50 });
  const parsed = resultSchema.safeParse(data);
  if (error || !parsed.success) {
    await finishOperationRun(admin, "inventory_allocator", runId, "failed", 0, "allocation_queue_failed");
    return NextResponse.json({ error: "Voorraadwachtrij kon niet veilig worden verwerkt." }, { status: 503 });
  }
  const { data: candidateData, error: candidateError } = await admin
    .schema("app")
    .rpc("list_order_qr_identity_candidates", { p_limit: 10 });
  const candidates = candidateSchema.safeParse(candidateData);
  if (candidateError || !candidates.success) {
    await finishOperationRun(
      admin,
      "inventory_allocator",
      runId,
      "failed",
      parsed.data.processed + expiredGrants.data.expired,
      "qr_candidate_query_failed",
    );
    return NextResponse.json(
      { error: "QR-provisioning kon niet veilig worden voorbereid." },
      { status: 503 },
    );
  }
  let qrProvisioned = 0;
  try {
    const keyVersion = candidates.data.candidates.length > 0
      ? qrKeyVersion()
      : 1;
    const pepperFingerprint = candidates.data.candidates.length > 0
      ? qrPepperFingerprint()
      : "";
    const provisionDeadline = Date.now() + 20_000;
    for (const candidate of candidates.data.candidates) {
      if (Date.now() > provisionDeadline) {
        throw new Error("QR_PROVISION_BUDGET_EXCEEDED");
      }
      const nonce = generateQrDerivationNonce();
      const locator = deriveQrLocator({
        generation: candidate.generation,
        keyVersion,
        nonce,
        orderId: candidate.orderId,
      });
      const { error: provisionError } = await admin
        .schema("app")
        .rpc("register_order_qr_locator", {
          p_generation: candidate.generation,
          p_key_version: keyVersion,
          p_derivation_nonce: nonce,
          p_locator_hash: hashQrLocator(locator),
          p_order_id: candidate.orderId,
          p_pepper_fingerprint: pepperFingerprint,
          p_request_id: randomUUID(),
        });
      if (provisionError) throw new Error("QR_PROVISION_FAILED");
      qrProvisioned += 1;
    }
  } catch {
    await finishOperationRun(
      admin,
      "inventory_allocator",
      runId,
      "failed",
      parsed.data.processed
        + qrProvisioned
        + expiredGrants.data.expired,
      "qr_provision_failed",
    );
    return NextResponse.json(
      { error: "QR-identiteiten konden niet veilig worden geprovisioneerd." },
      { status: 503 },
    );
  }
  const status = parsed.data.failed > 0
    ? "failed"
    : parsed.data.disabled && qrProvisioned === 0
      ? "paused"
      : "succeeded";
  if (!await finishOperationRun(
    admin,
    "inventory_allocator",
    runId,
    status,
    parsed.data.processed + qrProvisioned,
    parsed.data.failed > 0 ? "allocation_job_failed" : null,
  )) {
    return NextResponse.json({ error: "Voorraadworkerresultaat kon niet worden gemonitord." }, { status: 503 });
  }
  return NextResponse.json({
    status,
    processed: parsed.data.processed,
    completed: parsed.data.completed,
    retryable: parsed.data.retryable,
    exhausted: parsed.data.exhausted,
    failed: parsed.data.failed,
    qrGrantsExpired: expiredGrants.data.expired,
    qrProvisioned,
  }, { status: parsed.data.failed > 0 ? 503 : 200 });
}
