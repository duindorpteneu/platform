import { NextResponse } from "next/server";
import { z } from "zod";
import { getServerEnv } from "@/lib/env";
import { consumeRateLimit, requestRateKey, valueRateKey } from "@/server/auth/rate-limit";
import { normalizeParentEmail } from "@/server/auth/parent";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

const requestSchema = z.object({ email: z.string().trim().email().max(254) }).strict();
const neutralResponse = { message: "Als dit e-mailadres bij een medewerkersaccount hoort, is een herstellink verzonden." };

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const environment = getServerEnv();
  const guarded = guardBrowserMutation(request, { appBaseUrl: environment.APP_BASE_URL, body: BODY_POLICIES.jsonTiny });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
  if (!body.ok) return body.response;
  const parsed = requestSchema.safeParse(body.data);
  if (!parsed.success) return NextResponse.json({ error: "Voer een geldig e-mailadres in." }, { status: 400 });

  const admin = getSupabaseAdminClient();
  if (!admin) return NextResponse.json(neutralResponse, { status: 202 });
  const email = normalizeParentEmail(parsed.data.email);
  try {
    const [ipAllowed, emailAllowed] = await Promise.all([
      consumeRateLimit(admin, { scope: "staff_recovery", keyHash: requestRateKey(request, "staff-recovery-ip"), limit: 10, windowSeconds: 3_600 }),
      consumeRateLimit(admin, { scope: "staff_recovery", keyHash: valueRateKey("staff-recovery-email", email), limit: 3, windowSeconds: 3_600 }),
    ]);
    if (ipAllowed && emailAllowed) {
      await admin.auth.resetPasswordForEmail(email, {
        redirectTo: new URL("/staff/reset-password", environment.APP_BASE_URL).toString(),
      });
    }
  } catch {
    // Antwoord blijft bewust gelijk voor onbekende accounts, providerfouten en rate limits.
  }
  return NextResponse.json(neutralResponse, { status: 202 });
}
