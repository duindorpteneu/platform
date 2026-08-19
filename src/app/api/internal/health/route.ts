import { NextResponse } from "next/server";
import {
  operationalHealthIsDegraded,
  operationalHealthSchema,
} from "@/lib/operations-contract";
import { hasInternalBearer } from "@/server/operations/internal-auth";
import { emailRuntimeHealth } from "@/server/email/provider";
import { qrAcceptedKeyMetadata } from "@/server/qr/tokens";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  if (!hasInternalBearer(request)) return NextResponse.json({ error: "Geen toegang tot operationele status." }, { status: 401 });
  let failureStage = "health_setup";
  try {
    const admin = getSupabaseAdminClient();
    if (!admin) return NextResponse.json({ status: "degraded", error: "database_unavailable" }, { status: 503 });
    const qrKeys = qrAcceptedKeyMetadata();
    failureStage = "health_database";
    const { data, error } = await admin
      .schema("app")
      .rpc("get_operational_health_v13", {
        p_current_key_version: qrKeys.current.version,
        p_current_pepper_fingerprint: qrKeys.current.fingerprint,
        p_previous_key_version: qrKeys.previous?.version ?? null,
        p_previous_pepper_fingerprint:
          qrKeys.previous?.fingerprint ?? null,
      });
    if (error) return NextResponse.json({ status: "degraded", error: "health_database_failed" }, { status: 503 });
    const parsed = operationalHealthSchema.safeParse(data);
    if (!parsed.success) return NextResponse.json({ status: "degraded", error: "health_response_invalid" }, { status: 502 });
    failureStage = "health_runtime";
    const runtimeImportValue = process.env.DYNAMIC_IMPORT_ENABLED?.trim();
    const runtimeImportEnabled = runtimeImportValue === "true";
    const importGateMismatch = !["true", "false"].includes(runtimeImportValue ?? "")
      || runtimeImportEnabled !== parsed.data.importControl.processingEnabled;
    const emailRuntime = emailRuntimeHealth();
    const emailGateMismatch = !emailRuntime.runtimeValueValid
      || emailRuntime.runtimeEnabled
        !== parsed.data.emailControl.processingEnabled;
    const emailProviderInvalid = emailRuntime.runtimeEnabled
      && (
        !emailRuntime.providerConfigured
        || !emailRuntime.keyFingerprintMatches
      );
    const degraded = operationalHealthIsDegraded(parsed.data)
      || importGateMismatch
      || emailGateMismatch
      || emailProviderInvalid
      || parsed.data.emailControl.testEventQuarantined > 0;
    failureStage = "health_response";
    return NextResponse.json(
      {
        status: degraded ? "degraded" : "healthy",
        importGateMatches: !importGateMismatch,
        ...parsed.data,
        emailControl: {
          runtimeEnabled: emailRuntime.runtimeEnabled,
          databaseEnabled:
            parsed.data.emailControl.processingEnabled,
          gateMatches: !emailGateMismatch,
          providerConfigured: emailRuntime.providerConfigured,
          provider: emailRuntime.provider,
          keyFingerprintMatches:
            emailRuntime.keyFingerprintMatches,
          testEventQuarantined:
            parsed.data.emailControl.testEventQuarantined,
        },
      },
      { status: degraded ? 503 : 200, headers: { "Cache-Control": "no-store" } },
    );
  } catch {
    return NextResponse.json(
      { status: "degraded", error: `${failureStage}_failed` },
      { status: 503, headers: { "Cache-Control": "no-store" } },
    );
  }
}
