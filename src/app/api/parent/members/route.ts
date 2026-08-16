import { NextResponse } from "next/server";
import QRCode from "qrcode";
import {
  parentPackageWorkspaceDatabaseSchema,
  parentPackageWorkspaceResponseSchema,
  type ParentPackageWorkspace,
  type ParentPackageWorkspaceDatabase,
} from "@/lib/parent-package-contract";
import { getParentSession } from "@/server/auth/parent-session";
import { deriveQrLocator } from "@/server/qr/tokens";
import { operationalLogger } from "@/server/security/logger";
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
  const qrIdentityParts = order
    ? [order.qrVersion, order.qrKeyVersion, order.qrNonce]
    : [];
  if (
    qrIdentityParts.some((part) => part !== null)
    && qrIdentityParts.some((part) => part === null)
  ) {
    throw new Error("QR_IDENTITY_INCOMPLETE");
  }
  if (
    !order
    || !["paid", "duplicate_paid"].includes(order.paymentStatus ?? "")
    || !order.qrVersion
    || !order.qrKeyVersion
    || !order.qrNonce
    || !order.articleLines.some((line) => line.status === "ready_for_pickup")
  ) {
    return null;
  }

  const locator = deriveQrLocator({
    generation: order.qrVersion,
    keyVersion: order.qrKeyVersion,
    nonce: order.qrNonce,
    orderId: order.id,
  });
  return QRCode.toDataURL(locator, {
    width: 256,
    margin: 2,
    errorCorrectionLevel: "M",
    color: { dark: "#0b2e63", light: "#ffffff" },
  });
}

export async function GET() {
  const session = await getParentSession();
  const admin = getSupabaseAdminClient();
  if (!session || !admin) {
    return response({ error: "Oudersessie vereist." }, 401);
  }

  const { data, error } = await admin.rpc("get_parent_package_workspace_v6", {
    p_token_hash: session.tokenHash,
  });
  if (error) {
    operationalLogger.error("parent.workspace_rpc_failed", {
      code: "parent_workspace_v6_rpc_error",
      provider: "supabase",
      route: "/api/parent/members",
      status: 503,
    });
    return response({ error: "De leden konden niet worden geladen." }, 503);
  }

  const parsed = parentPackageWorkspaceDatabaseSchema.safeParse(data);
  if (!parsed.success) {
    operationalLogger.error("parent.workspace_schema_invalid", {
      code: "parent_workspace_v6_schema_invalid",
      provider: "supabase",
      route: "/api/parent/members",
      status: 502,
    });
    return response({ error: "Ongeldig antwoord van de database." }, 502);
  }

  let members: ParentPackageWorkspace["members"];
  try {
    members = await Promise.all(parsed.data.members.map(async (member) => {
      if (!member.order) return { ...member, order: null };
      const {
        qrKeyVersion,
        qrNonce,
        ...publicOrder
      } = member.order;
      if ((qrKeyVersion === null) !== (qrNonce === null)) {
        throw new Error("QR_IDENTITY_INCOMPLETE");
      }
      return {
        ...member,
        order: {
          ...publicOrder,
          qrDataUrl: await qrDataUrl(member.order),
        },
      };
    }));
  } catch {
    return response(
      { error: "De afhaalcode kon niet veilig worden opgebouwd." },
      503,
    );
  }
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
