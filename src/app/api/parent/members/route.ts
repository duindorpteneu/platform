import { NextResponse } from "next/server";
import { getParentSession } from "@/server/auth/parent-session";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import { deriveQrBearerToken } from "@/server/qr/tokens";
import { getServerEnv } from "@/lib/env";
import QRCode from "qrcode";

type ParentMemberRow = Record<string, unknown> & {
  order_id: string | null;
  payment_status: string | null;
  qr_version: number | null;
};

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET() {
  const session = await getParentSession();
  const admin = getSupabaseAdminClient();
  if (!session || !admin) return NextResponse.json({ error: "Oudersessie vereist." }, { status: 401 });
  const { data, error } = await admin.rpc("get_parent_members", { p_token_hash: session.tokenHash });
  if (error) return NextResponse.json({ error: "De leden konden niet worden geladen." }, { status: 503 });
  const members = await Promise.all((data ?? []).map(async (member: ParentMemberRow) => {
    if (member.payment_status !== "paid" || !member.order_id || !member.qr_version) return { ...member, qr_data_url: null };
    const token = deriveQrBearerToken(member.order_id, member.qr_version);
    const payload = new URL("/qr", getServerEnv().APP_BASE_URL);
    payload.searchParams.set("token", token);
    const qrDataUrl = await QRCode.toDataURL(payload.toString(), {
      width: 256,
      margin: 2,
      errorCorrectionLevel: "M",
      color: { dark: "#0b2e63", light: "#ffffff" },
    });
    return { ...member, qr_data_url: qrDataUrl };
  }));
  return NextResponse.json({ members });
}
