import { NextResponse } from "next/server";
import {
  supplierAdminActionSchema,
  supplierAdminResultSchema,
  supplierAdminWorkspaceSchema,
} from "@/lib/supplier-contract";
import { requireStaffSessionBinding } from "@/server/auth/staff";
import {
  generateSupplierAccessToken,
  hashSupplierSecret,
} from "@/server/auth/supplier-context";
import {
  BODY_POLICIES,
  guardBrowserMutation,
  readJsonRequest,
} from "@/server/security/route-guard";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
const privateHeaders = { "Cache-Control": "private, no-store, max-age=0" };

export async function GET() {
  try {
    const staff = await requireStaffSessionBinding(["beheerder"]);
    const admin = getSupabaseAdminClient();
    if (!admin) {
      return NextResponse.json(
        { error: "Leverancierstoegang is tijdelijk niet beschikbaar." },
        { status: 503, headers: privateHeaders },
      );
    }
    const { data, error } = await admin.schema("app").rpc(
      "get_supplier_planner_admin_workspace_v1",
      {
        p_actor_id: staff.userId,
        p_staff_session_hash: staff.sessionTokenHash,
      },
    );
    const parsed = supplierAdminWorkspaceSchema.safeParse(data);
    if (error?.code === "42501") {
      return NextResponse.json(
        { error: "Alleen beheerders mogen leverancierstoegang beheren." },
        { status: 403, headers: privateHeaders },
      );
    }
    if (error || !parsed.success) {
      return NextResponse.json(
        { error: "Leverancierstoegang kon niet veilig worden gelezen." },
        { status: 503, headers: privateHeaders },
      );
    }
    return NextResponse.json(parsed.data, { headers: privateHeaders });
  } catch {
    return NextResponse.json(
      { error: "Alleen beheerders mogen leverancierstoegang beheren." },
      { status: 403, headers: privateHeaders },
    );
  }
}

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, {
    body: BODY_POLICIES.jsonTiny,
  });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
  if (!body.ok) return body.response;
  const parsed = supplierAdminActionSchema.safeParse(body.data);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Controleer de leverancieractie, seizoenen en reden." },
      { status: 400, headers: privateHeaders },
    );
  }

  try {
    const staff = await requireStaffSessionBinding(["beheerder"]);
    const admin = getSupabaseAdminClient();
    if (!admin) {
      return NextResponse.json(
        { error: "Leverancierstoegang is tijdelijk niet beschikbaar." },
        { status: 503, headers: privateHeaders },
      );
    }
    const accessToken = parsed.data.action === "create"
      || parsed.data.action === "rotate"
      ? generateSupplierAccessToken()
      : null;
    const { data, error } = await admin.schema("app").rpc(
      "manage_supplier_planner_v1",
      {
        p_access_token_hash: accessToken
          ? await hashSupplierSecret(accessToken)
          : null,
        p_action: parsed.data.action,
        p_actor_id: staff.userId,
        p_display_name: parsed.data.action === "create"
          ? parsed.data.displayName
          : null,
        p_principal_id: parsed.data.action === "create"
          ? null
          : parsed.data.principalId,
        p_reason: parsed.data.action === "create"
          ? null
          : parsed.data.reason,
        p_request_id: parsed.data.requestId,
        p_season_ids: parsed.data.action === "create"
          || parsed.data.action === "set_seasons"
          ? parsed.data.seasonIds
          : null,
        p_staff_session_hash: staff.sessionTokenHash,
      },
    );
    if (error?.code === "42501") {
      return NextResponse.json(
        { error: "Alleen beheerders mogen leverancierstoegang beheren." },
        { status: 403, headers: privateHeaders },
      );
    }
    if (error?.code === "P0002") {
      return NextResponse.json(
        { error: "Deze leverancierstoegang bestaat niet meer." },
        { status: 404, headers: privateHeaders },
      );
    }
    if (error?.code === "23505") {
      return NextResponse.json(
        { error: "Deze actie is al met andere invoer verwerkt." },
        { status: 409, headers: privateHeaders },
      );
    }
    if (error?.code === "22023") {
      return NextResponse.json(
        { error: "Controleer de open seizoenen en verplichte reden." },
        { status: 400, headers: privateHeaders },
      );
    }
    const result = supplierAdminResultSchema.safeParse(data);
    if (error || !result.success) {
      return NextResponse.json(
        { error: "De leverancieractie kon niet veilig worden opgeslagen." },
        { status: 503, headers: privateHeaders },
      );
    }
    return NextResponse.json(
      {
        ...result.data,
        accessToken: accessToken && !result.data.alreadyProcessed
          ? accessToken
          : undefined,
      },
      { headers: privateHeaders },
    );
  } catch {
    return NextResponse.json(
      { error: "Alleen beheerders mogen leverancierstoegang beheren." },
      { status: 403, headers: privateHeaders },
    );
  }
}
