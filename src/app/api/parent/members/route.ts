import { NextResponse } from "next/server";
import QRCode from "qrcode";
import {
  parentPackageWorkspaceDatabaseSchema,
  parentPackageWorkspaceResponseSchema,
  type ParentPackageWorkspace,
  type ParentPackageWorkspaceDatabase,
} from "@/lib/parent-package-contract";
import { getServerEnv } from "@/lib/env";
import { getParentSession } from "@/server/auth/parent-session";
import { deriveQrBearerToken } from "@/server/qr/tokens";
import { getSupabaseAdminClient } from "@/server/supabase/admin";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const privateHeaders = {
  "Cache-Control": "private, no-store, max-age=0",
  Pragma: "no-cache",
  Vary: "Cookie",
};

function response(
  body: unknown,
  status = 200,
) {
  return NextResponse.json(body, { status, headers: privateHeaders });
}

async function qrDataUrl(
  order: ParentPackageWorkspaceDatabase["members"][number]["order"],
) {
  if (
    !order
    || !["paid", "duplicate_paid"].includes(order.paymentStatus ?? "")
    || !order.qrVersion
    || !order.articleLines.some((line) => line.status === "ready_for_pickup")
  ) {
    return null;
  }

  try {
    const token = deriveQrBearerToken(order.id, order.qrVersion);
    const payload = new URL("/qr", getServerEnv().APP_BASE_URL);
    payload.searchParams.set("token", token);
    return await QRCode.toDataURL(payload.toString(), {
      width: 256,
      margin: 2,
      errorCorrectionLevel: "M",
      color: { dark: "#0b2e63", light: "#ffffff" },
    });
  } catch {
    return null;
  }
}

export async function GET() {
  const session = await getParentSession();
  const admin = getSupabaseAdminClient();
  if (!session || !admin) {
    return response({ error: "Oudersessie vereist." }, 401);
  }

  const { data, error } = await admin.rpc("get_parent_package_workspace_v3", {
    p_token_hash: session.tokenHash,
  });
  if (error) {
    return response({ error: "De leden konden niet worden geladen." }, 503);
  }

  const parsed = parentPackageWorkspaceDatabaseSchema.safeParse(data);
  if (!parsed.success) {
    return response({ error: "Ongeldig antwoord van de database." }, 502);
  }

  const members = await Promise.all(parsed.data.members.map(async (member) => ({
    ...member,
    order: member.order
      ? { ...member.order, qrDataUrl: await qrDataUrl(member.order) }
      : null,
  })));
  const workspace: ParentPackageWorkspace = {
    enabled: parsed.data.enabled,
    members,
  };
  const output = parentPackageWorkspaceResponseSchema.safeParse(workspace);
  if (!output.success) {
    return response({ error: "Ongeldig portaalantwoord." }, 502);
  }
  return response(output.data);
}
