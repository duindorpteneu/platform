import { NextResponse } from "next/server";
import { extractMollieWebhookPaymentId } from "@/server/payments/mollie";
import {
  getMollieRuntimeConfig,
  MollieServiceError,
  reconcileMollieWebhook,
  type MollieRpcClient,
} from "@/server/payments/mollie-service";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import { RequestBodyError } from "@/server/security/request";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const responseHeaders = { "Cache-Control": "no-store" };

export async function POST(request: Request) {
  let providerPaymentId: string;
  try {
    providerPaymentId = await extractMollieWebhookPaymentId(request);
  } catch (error) {
    if (error instanceof RequestBodyError) {
      return NextResponse.json({ received: false }, { status: error.status, headers: responseHeaders });
    }
    return NextResponse.json({ received: false }, { status: 400, headers: responseHeaders });
  }

  let admin;
  let config;
  try {
    config = getMollieRuntimeConfig();
    admin = getSupabaseAdminClient();
  } catch {
    return NextResponse.json({ received: false }, { status: 503, headers: responseHeaders });
  }
  if (!admin) return NextResponse.json({ received: false }, { status: 503, headers: responseHeaders });

  try {
    await reconcileMollieWebhook(providerPaymentId, {
      database: admin as unknown as MollieRpcClient,
      config,
    });
    return NextResponse.json({ received: true }, { headers: responseHeaders });
  } catch (error) {
    if (error instanceof MollieServiceError) {
      if (error.code === "NOT_CONFIGURED" || error.retryable) {
        return NextResponse.json({ received: false }, { status: 503, headers: responseHeaders });
      }
      // Een onbekende of inhoudelijk afgewezen providerbetaling is niet retrybaar.
      // De actuele providerstatus is wel opgehaald; er wordt geen lokale mutatie uitgevoerd.
      return NextResponse.json({ received: true }, { headers: responseHeaders });
    }
    return NextResponse.json({ received: false }, { status: 503, headers: responseHeaders });
  }
}
