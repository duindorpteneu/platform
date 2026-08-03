import { NextResponse } from "next/server";
import { operationalHealthSchema } from "@/lib/operations-contract";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const headers = { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" };

function releaseIdentity() {
  const environment = process.env.APP_ENVIRONMENT;
  const revision = process.env.RELEASE_SHA;
  const value = (name: string) => process.env[name]?.trim() ?? "";
  const expectedOrigin = environment === "staging" ? "https://staging-duindorp.dgwebservices.nl" : "https://duindorp.dgwebservices.nl";
  const importEnabled = value("DYNAMIC_IMPORT_ENABLED");
  const importRetention = value("IMPORT_RAW_RETENTION_HOURS");
  const importKey = value("IMPORT_STAGING_ENCRYPTION_KEY");
  const importKeyValid = importKey === "" || (
    /^[A-Za-z0-9_-]{43}$/.test(importKey)
    && Buffer.from(importKey, "base64url").byteLength === 32
    && Buffer.from(importKey, "base64url").toString("base64url") === importKey
  );
  if (
    !["staging", "production"].includes(environment ?? "")
    || !/^[a-f0-9]{40}$/.test(revision ?? "")
    || value("APP_BASE_URL") !== expectedOrigin
    || !/^https:\/\/[a-z0-9]{20}\.supabase\.co$/.test(value("NEXT_PUBLIC_SUPABASE_URL"))
    || value("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY").length < 20
    || value("SUPABASE_SECRET_KEY").length < 20
    || value("NEXT_SERVER_ACTIONS_ENCRYPTION_KEY").length < 40
    || value("PARENT_TOKEN_PEPPER").length < 32
    || value("CRON_SECRET").length < 16
    || !["true", "false"].includes(importEnabled)
    || !/^(?:[1-9]|[1-6][0-9]|7[0-2])$/.test(importRetention)
    || !importKeyValid
    || (importEnabled === "true" && importKey === "")
  ) return null;
  return {
    identity: { service: "duindorpteneu", environment, revision },
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
    const { data, error } = await admin.schema("app").rpc("get_operational_health_v4");
    const parsed = operationalHealthSchema.safeParse(data);
    const valid = !error
      && parsed.success
      && (
        !parsed.data.importControl.processingEnabled
        || parsed.data.importControl.cutoverActive
      )
      && releaseConfig.importEnabled
        === parsed.data.importControl.processingEnabled;
    return NextResponse.json({ status: valid ? "ok" : "degraded", ...release }, { status: valid ? 200 : 503, headers });
  } catch {
    return NextResponse.json({ status: "degraded", ...release }, { status: 503, headers });
  }
}
