import { NextResponse } from "next/server";
import {
  emailDeliveryAttemptHealthHasIntegrityBlocker,
  operationalHealthSchema,
} from "@/lib/operations-contract";
import { emailRuntimeHealth } from "@/server/email/provider";
import { qrAcceptedKeyMetadata } from "@/server/qr/tokens";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const headers = { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" };

function releaseIdentity() {
  const environment = process.env.APP_ENVIRONMENT;
  const revision = process.env.RELEASE_SHA;
  const artifactDigest = process.env.RELEASE_ARTIFACT_DIGEST;
  const value = (name: string) => process.env[name]?.trim() ?? "";
  const expectedOrigin = environment === "staging" ? "https://duindorpsv.dgwebservices.nl" : "https://duindorp.dgwebservices.nl";
  const importEnabled = value("DYNAMIC_IMPORT_ENABLED");
  const importRetention = value("IMPORT_RAW_RETENTION_HOURS");
  const importKey = value("IMPORT_STAGING_ENCRYPTION_KEY");
  const canonicalSecret = (secret: string) => (
    /^[A-Za-z0-9_-]{43}$/.test(secret)
    && Buffer.from(secret, "base64url").byteLength === 32
    && Buffer.from(secret, "base64url").toString("base64url") === secret
  );
  const importKeyValid = importKey === "" || canonicalSecret(importKey);
  const qrPepper = value("QR_TOKEN_PEPPER");
  const qrVersion = value("QR_TOKEN_PEPPER_VERSION");
  const previousQrPepper = value("QR_TOKEN_PREVIOUS_PEPPER");
  const previousQrVersion = value("QR_TOKEN_PREVIOUS_PEPPER_VERSION");
  const previousQrPairValid = (
    previousQrPepper === ""
    && previousQrVersion === ""
  ) || (
    canonicalSecret(previousQrPepper)
    && /^[1-9][0-9]{0,3}$/.test(previousQrVersion)
    && previousQrVersion !== qrVersion
  );
  if (
    !["staging", "production"].includes(environment ?? "")
    || !/^[a-f0-9]{40}$/.test(revision ?? "")
    || !/^sha256:[a-f0-9]{64}$/.test(artifactDigest ?? "")
    || value("APP_BASE_URL") !== expectedOrigin
    || !/^https:\/\/[a-z0-9]{20}\.supabase\.co$/.test(value("NEXT_PUBLIC_SUPABASE_URL"))
    || value("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY").length < 20
    || value("SUPABASE_SECRET_KEY").length < 20
    || value("NEXT_SERVER_ACTIONS_ENCRYPTION_KEY").length < 40
    || value("PARENT_TOKEN_PEPPER").length < 32
    || !canonicalSecret(qrPepper)
    || !/^[1-9][0-9]{0,3}$/.test(qrVersion)
    || !previousQrPairValid
    || value("CRON_SECRET").length < 16
    || !["true", "false"].includes(importEnabled)
    || !/^(?:[1-9]|[1-6][0-9]|7[0-2])$/.test(importRetention)
    || !importKeyValid
    || (importEnabled === "true" && importKey === "")
  ) return null;
  return {
    identity: {
      service: "duindorpteneu",
      environment,
      revision,
      artifactDigest,
    },
    importEnabled: importEnabled === "true",
  };
}

export async function GET() {
  const releaseConfig = releaseIdentity();
  if (!releaseConfig) return NextResponse.json({ status: "degraded", service: "duindorpteneu" }, { status: 503, headers });
  const release = releaseConfig.identity;
  try {
    const admin = getSupabaseAdminClient();
    if (!admin) return NextResponse.json({ status: "degraded", ...release }, { status: 503, headers });
    const qrKeys = qrAcceptedKeyMetadata();
    const { data, error } = await admin.schema("app").rpc(
      "get_operational_health_v15",
      {
        p_current_key_version: qrKeys.current.version,
        p_current_pepper_fingerprint: qrKeys.current.fingerprint,
        p_previous_key_version: qrKeys.previous?.version ?? null,
        p_previous_pepper_fingerprint:
          qrKeys.previous?.fingerprint ?? null,
      },
    );
    const parsed = operationalHealthSchema.safeParse(data);
    const emailRuntime = emailRuntimeHealth();
    const valid = !error
      && parsed.success
      && emailRuntime.runtimeValueValid
      && emailRuntime.runtimeEnabled
        === parsed.data.emailControl.processingEnabled
      && (
        !emailRuntime.runtimeEnabled
        || (
          emailRuntime.providerConfigured
          && emailRuntime.keyFingerprintMatches
        )
      )
      && parsed.data.emailControl.testEventQuarantined === 0
      && parsed.data.brandingProjection.blockers === 0
      && (
        !parsed.data.importControl.processingEnabled
        || parsed.data.importControl.cutoverActive
      )
      && parsed.data.qrControl.keyMismatchActiveLocators === 0
      && parsed.data.qrControl.keyMismatchOpenGrants === 0
      && !emailDeliveryAttemptHealthHasIntegrityBlocker(parsed.data)
      && parsed.data.reminderPlanner.failedRunsRecent === 0
      && parsed.data.reminderPlanner.activeRulesNeverRun === 0
      && parsed.data.parentOtpDelivery.stalePrepared === 0
      && parsed.data.parentOtpDelivery.deliveryUncertainRecent === 0
      && parsed.data.parentOtpDelivery.sendFailuresRecent === 0
      && parsed.data.parentOtpDelivery.quarantinedEvents === 0
      && parsed.data.parentOtpDelivery.providerFailuresRecent === 0
      && parsed.data.supplierPlanning.activePrincipalsWithoutOpenSeason === 0
      && parsed.data.supplierPlanning.unauthorizedActiveSessions === 0
      && parsed.data.supplierPlanning.expiredUnrevokedSessions === 0
      && parsed.data.supplierPlanning.recentLoginFailures < 50
      && parsed.data.supplierPlanning.staleCredentials === 0
      && (
        !releaseConfig.importEnabled
        || parsed.data.importControl.processingEnabled
      );
    return NextResponse.json({ status: valid ? "ok" : "degraded", ...release }, { status: valid ? 200 : 503, headers });
  } catch {
    return NextResponse.json({ status: "degraded", ...release }, { status: 503, headers });
  }
}
