import { NextResponse } from "next/server";
import { getServerEnv } from "@/lib/env";
import { portalAccessActivateRequestSchema } from "@/lib/portal-access-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { portalAccessExceptionResponse, portalAccessRpcErrorResponse } from "@/server/portal-access/http";
import { activatePortalAccess } from "@/server/portal-access/workspace";
import { normalizeCorrelationId } from "@/server/security/correlation";
import { verifyPortalAccessPreviewToken } from "@/server/security/portal-access-preview-token";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonStandard });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonStandard);
  if (!body.ok) return body.response;
  const parsed = portalAccessActivateRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return NextResponse.json({ error: "Ongeldige activatiebevestiging." }, { status: 400 });
  }
  try {
    const staff = await requireStaffRole(["beheerder"]);
    const pepper = getServerEnv().PARENT_TOKEN_PEPPER;
    if (!pepper) throw new Error("PORTAL_ACCESS_PREVIEW_PEPPER_MISSING");
    const preview = verifyPortalAccessPreviewToken(
      parsed.data.previewToken,
      pepper,
      {
        operation: "activate",
        actorId: staff.userId,
        seasonId: parsed.data.seasonId,
        ids: parsed.data.memberSeasonIds,
      },
    );
    const result = await activatePortalAccess({
      seasonId: parsed.data.seasonId,
      memberSeasonIds: parsed.data.memberSeasonIds,
      expectedRevision: preview.revision,
      batchKey: parsed.data.batchKey,
      correlationId: normalizeCorrelationId(request.headers.get("x-correlation-id")),
    });
    if (result.error) return portalAccessRpcErrorResponse(result.error);
    return NextResponse.json(result.data);
  } catch (error) {
    return portalAccessExceptionResponse(error);
  }
}
