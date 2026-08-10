import { NextResponse } from "next/server";
import { actionItemQuerySchema } from "@/lib/action-item-contract";
import {
  actionItemError,
  actionItemExceptionResponse,
  actionItemRpcErrorResponse,
} from "@/server/action-items/http";
import { getActionItemWorkspace } from "@/server/action-items/workspace";
import {
  BODY_POLICIES,
  guardBrowserMutation,
  readJsonRequest,
} from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, {
    body: BODY_POLICIES.jsonSmall,
  });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonSmall);
  if (!body.ok) return body.response;
  const parsed = actionItemQuerySchema.safeParse(body.data);
  if (!parsed.success) {
    return actionItemError("Ongeldige actiepuntfilters.", 400);
  }

  try {
    const result = await getActionItemWorkspace(parsed.data);
    if (result.error) return actionItemRpcErrorResponse(result.error);
    return NextResponse.json(result.data, {
      headers: { "Cache-Control": "private, no-store, max-age=0" },
    });
  } catch (error) {
    return actionItemExceptionResponse(error);
  }
}
