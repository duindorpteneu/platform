import { randomUUID } from "node:crypto";
import { NextResponse } from "next/server";
import { mollieCreateRequestSchema } from "@/lib/mollie-contract";
import { resolveParentSession } from "@/server/auth/parent-session";
import {
  getMollieRuntimeConfig,
  hasTrustedPaymentOrigin,
  MollieServiceError,
  startMollieCheckout,
  type MollieRpcClient,
} from "@/server/payments/mollie-service";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import { consumeRateLimit } from "@/server/auth/rate-limit";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";
import { isOperationalFeatureEnabled, type FeatureFlagClient } from "@/server/operations/feature-flags";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const responseHeaders = { "Cache-Control": "no-store" };

type MollieFailurePhase = "configuration" | "paused" | "database" | "provider" | "provider_response" | "unknown";

function failure(message: string, status: number, extraHeaders: Record<string, string> = {}) {
  return NextResponse.json({ error: message }, { status, headers: { ...responseHeaders, ...extraHeaders } });
}

function unavailable(message: string, phase: MollieFailurePhase) {
  return failure(message, 503, { "X-Duindorp-Mollie-Phase": phase });
}

export async function POST(request: Request) {
  let config;
  try {
    config = getMollieRuntimeConfig();
  } catch {
    return unavailable("Online betalen is tijdelijk niet beschikbaar.", "configuration");
  }
  const guarded = guardBrowserMutation(request, { appBaseUrl: config.appBaseUrl, body: BODY_POLICIES.jsonTiny });
  if (guarded || !hasTrustedPaymentOrigin(request, config.appBaseUrl)) {
    if (guarded) return guarded;
    return failure("Dit betaalverzoek kon niet veilig worden gecontroleerd.", 403);
  }

  const parentSession = await resolveParentSession();
  const session = parentSession.session;
  const admin = getSupabaseAdminClient();
  if (!session || !admin) {
    return failure("Log opnieuw in om veilig te betalen.", 401, {
      "X-Duindorp-Parent-Session-Phase": !admin ? "admin_unavailable" : parentSession.phase,
    });
  }
  if (!await isOperationalFeatureEnabled(admin as unknown as FeatureFlagClient, "mollie_enabled")) {
    return unavailable("Online betalen is tijdelijk gepauzeerd.", "paused");
  }
  const allowed = await consumeRateLimit(admin, { scope: "mollie_create", keyHash: session.tokenHash, limit: 10, windowSeconds: 600 });
  if (!allowed) return failure("Te veel betaalpogingen. Probeer het over enkele minuten opnieuw.", 429);

  const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
  if (!body.ok) return body.response;
  const parsed = mollieCreateRequestSchema.safeParse(body.data);
  if (!parsed.success) return failure("Ongeldig betaalverzoek.", 400);

  try {
    const result = await startMollieCheckout({
      tokenHash: session.tokenHash,
      orderId: parsed.data.orderId,
      idempotencyKey: randomUUID(),
    }, {
      database: admin as unknown as MollieRpcClient,
      config,
    });
    return NextResponse.json(result, { headers: responseHeaders });
  } catch (error) {
    if (error instanceof MollieServiceError) {
      if (error.code === "ORDER_ALREADY_PAID") return failure("Deze bestelling is al betaald.", 409);
      if (error.code === "ORDER_NOT_AVAILABLE") return failure("Deze bestelling is niet beschikbaar.", 404);
      if (error.code === "NOT_CONFIGURED") return unavailable("Online betalen is tijdelijk niet beschikbaar.", "configuration");
      if (error.code === "DATABASE_UNAVAILABLE") return unavailable("De betaalomgeving is tijdelijk niet bereikbaar. Probeer het later opnieuw.", "database");
      if (error.code === "PROVIDER_UNAVAILABLE") return unavailable("De betaalomgeving is tijdelijk niet bereikbaar. Probeer het later opnieuw.", "provider");
      if (error.code === "INVALID_PROVIDER_RESPONSE") return unavailable("De betaalomgeving is tijdelijk niet bereikbaar. Probeer het later opnieuw.", "provider_response");
    }
    return unavailable("De betaalomgeving is tijdelijk niet bereikbaar. Probeer het later opnieuw.", "unknown");
  }
}
