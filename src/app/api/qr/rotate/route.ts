import { NextResponse } from "next/server";
import { requireStaffRole } from "@/server/auth/staff";
import { qrManagementRequestSchema } from "@/server/operations/requests";
import { deriveQrBearerToken, hashQrBearerToken } from "@/server/qr/tokens";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonStandard }); if (guarded) return guarded;
  try {
    const staff = await requireStaffRole(["beheerder", "kledingcommissie"]);
    const body = await readJsonRequest(request, BODY_POLICIES.jsonStandard);
    if (!body.ok) return body.response;
    const parsed = qrManagementRequestSchema.safeParse(body.data);
    if (!parsed.success) return NextResponse.json({ error: "Vul een geldige verplichte reden in." }, { status: 400 });
    const admin = getSupabaseAdminClient();
    if (!admin) return NextResponse.json({ error: "Databaseverbinding ontbreekt." }, { status: 503 });

    if (parsed.data.action === "revoke") {
      const { data, error } = await admin.schema("app").rpc("revoke_order_qr", {
        p_actor_id: staff.userId,
        p_order_id: parsed.data.orderId,
        p_reason: parsed.data.reason,
      });
      if (error) {
        if (error.code === "P0002") return NextResponse.json({ error: "Deze bestelling heeft geen actieve QR-code." }, { status: 404 });
        if (error.code === "42501") return NextResponse.json({ error: "Geen toegang tot QR-beheer." }, { status: 403 });
        return NextResponse.json({ error: "De QR-code kon niet veilig worden ingetrokken." }, { status: 409 });
      }
      return NextResponse.json(data);
    }

    const { data: context, error: contextError } = await admin.schema("app").rpc("get_order_qr_rotation_context", {
      p_actor_id: staff.userId,
      p_order_id: parsed.data.orderId,
    });
    const currentVersion = typeof context === "object" && context !== null && Number.isInteger((context as { currentVersion?: unknown }).currentVersion)
      ? (context as { currentVersion: number }).currentVersion
      : null;
    if (contextError?.code === "42501") return NextResponse.json({ error: "Geen toegang tot QR-beheer." }, { status: 403 });
    if (contextError?.code === "P0002") return NextResponse.json({ error: "Bestelling niet gevonden." }, { status: 404 });
    if (contextError || currentVersion === null) return NextResponse.json({ error: "Er bestaat nog geen QR-code om te roteren." }, { status: 409 });

    const nextVersion = currentVersion + 1;
    const bearer = deriveQrBearerToken(parsed.data.orderId, nextVersion);
    const { data, error } = await admin.schema("app").rpc("rotate_order_qr", {
      p_actor_id: staff.userId,
      p_order_id: parsed.data.orderId,
      p_expected_version: currentVersion,
      p_token_hash: hashQrBearerToken(bearer),
      p_reason: parsed.data.reason,
    });
    if (error) {
      if (error.code === "42501") return NextResponse.json({ error: "Geen toegang tot QR-beheer." }, { status: 403 });
      if (error.code === "P0002") return NextResponse.json({ error: "Bestelling niet gevonden." }, { status: 404 });
      if (error.code === "40001") return NextResponse.json({ error: "De QR-code is al door een andere actie gewijzigd. Vernieuw de pagina." }, { status: 409 });
      return NextResponse.json({ error: "De QR-code kon niet veilig worden geroteerd." }, { status: 409 });
    }
    return NextResponse.json(data);
  } catch (error) {
    if (error instanceof Error && error.message === "STAFF_AUTHORIZATION_REQUIRED") {
      return NextResponse.json({ error: "Geen toegang tot QR-beheer." }, { status: 403 });
    }
    return NextResponse.json({ error: "De QR-actie kon niet worden verwerkt." }, { status: 500 });
  }
}
