import { randomUUID } from "node:crypto";
import { NextResponse } from "next/server";
import { mollieCreateRequestSchema } from "@/lib/mollie-contract";
import { getParentSession } from "@/server/auth/parent-session";
import {
  getMollieRuntimeConfig,
  hasTrustedPaymentOrigin,
  MollieServiceError,
  startMollieCheckout,
  type MollieRpcClient,
} from "@/server/payments/mollie-service";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const responseHeaders = { "Cache-Control": "no-store" };

function failure(message: string, status: number) {
  return NextResponse.json({ error: message }, { status, headers: responseHeaders });
}

export async function POST(request: Request) {
  let config;
  try {
    config = getMollieRuntimeConfig();
  } catch {
    return failure("Online betalen is tijdelijk niet beschikbaar.", 503);
  }
  if (!hasTrustedPaymentOrigin(request, config.appBaseUrl)) {
    return failure("Dit betaalverzoek kon niet veilig worden gecontroleerd.", 403);
  }
  if (!request.headers.get("content-type")?.includes("application/json")) {
    return failure("Ongeldig betaalverzoek.", 415);
  }

  const contentLength = Number(request.headers.get("content-length") ?? 0);
  if (Number.isFinite(contentLength) && contentLength > 4_096) return failure("Ongeldig betaalverzoek.", 413);

  const session = await getParentSession();
  const admin = getSupabaseAdminClient();
  if (!session || !admin) return failure("Log opnieuw in om veilig te betalen.", 401);

  let payload: unknown;
  try {
    payload = await request.json();
  } catch {
    return failure("Ongeldig betaalverzoek.", 400);
  }
  const parsed = mollieCreateRequestSchema.safeParse(payload);
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
      if (error.code === "NOT_CONFIGURED") return failure("Online betalen is tijdelijk niet beschikbaar.", 503);
    }
    return failure("De betaalomgeving is tijdelijk niet bereikbaar. Probeer het later opnieuw.", 503);
  }
}
