import { NextResponse } from "next/server";
import { portalAccessQuerySchema } from "@/lib/portal-access-contract";
import { portalAccessExceptionResponse, portalAccessRpcErrorResponse } from "@/server/portal-access/http";
import { getPortalAccessWorkspace } from "@/server/portal-access/workspace";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonSmall });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonSmall);
  if (!body.ok) return body.response;
  const parsed = portalAccessQuerySchema.safeParse(body.data);
  if (!parsed.success) {
    return NextResponse.json({ error: "Ongeldige zoek- of paginakeuze." }, { status: 400 });
  }
  try {
    const result = await getPortalAccessWorkspace(parsed.data);
    if (result.error) return portalAccessRpcErrorResponse(result.error);
    return NextResponse.json(result.data, {
      headers: { "Cache-Control": "no-store, private" },
    });
  } catch (error) {
    return portalAccessExceptionResponse(error);
  }
}
