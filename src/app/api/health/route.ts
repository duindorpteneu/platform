import { NextResponse } from "next/server";
import { operationalHealthSchema } from "@/lib/operations-contract";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const headers = { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" };

export async function GET() {
  const admin = getSupabaseAdminClient();
  if (!admin) return NextResponse.json({ status: "degraded", version: process.env.npm_package_version ?? "0.1.0" }, { status: 503, headers });
  const { data, error } = await admin.schema("app").rpc("get_operational_health");
  const valid = !error && operationalHealthSchema.safeParse(data).success;
  return NextResponse.json({ status: valid ? "ok" : "degraded", version: process.env.npm_package_version ?? "0.1.0" }, { status: valid ? 200 : 503, headers });
}

