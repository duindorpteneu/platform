import { NextResponse } from "next/server";
import { requireStaffRole } from "@/server/auth/staff";
import { fulfilmentLookupRequestSchema, hashQrBearerToken } from "@/server/qr/tokens";
import { getSupabaseServerClient } from "@/server/supabase/server";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonStandard }); if (guarded) return guarded;
  try {
    await requireStaffRole();
    const body = await readJsonRequest(request, BODY_POLICIES.jsonStandard);
    if (!body.ok) return body.response;
    const parsed = fulfilmentLookupRequestSchema.safeParse(body.data);
    if (!parsed.success) return NextResponse.json({ status: "invalid" }, { status: 400 });
    const supabase = await getSupabaseServerClient();
    if (!supabase) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });

    const { data, error } = await supabase.schema("app").rpc("lookup_fulfilment", { p_token_hash: hashQrBearerToken(parsed.data.token) });
    if (error) {
      if (error.code === "42501") return NextResponse.json({ error: "Geen toegang tot uitgifte." }, { status: 403 });
      if (error.code === "P0001") return NextResponse.json({ error: "Te veel scanpogingen. Probeer het zo opnieuw." }, { status: 429 });
      return NextResponse.json({ error: "De QR-code kon niet worden gecontroleerd." }, { status: 500 });
    }
    return NextResponse.json(data);
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") return NextResponse.json({ error: "Geen toegang tot uitgifte." }, { status: 403 });
    return NextResponse.json({ error: "De QR-code kon niet worden verwerkt." }, { status: 500 });
  }
}
