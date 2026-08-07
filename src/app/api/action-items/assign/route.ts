import { NextResponse } from "next/server";
import { actionItemAssignRequestSchema } from "@/lib/action-item-contract";
import {
  actionItemError,
  actionItemExceptionResponse,
  actionItemRpcErrorResponse,
} from "@/server/action-items/http";
import { mutateActionItem } from "@/server/action-items/workspace";
import { normalizeCorrelationId } from "@/server/security/correlation";
import {
  BODY_POLICIES,
  guardBrowserMutation,
  readJsonRequest,
} from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, {
    body: BODY_POLICIES.jsonTiny,
  });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
  if (!body.ok) return body.response;
  const parsed = actionItemAssignRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return actionItemError("Ongeldige toewijzing.", 400);
  }

  try {
    const result = await mutateActionItem(
      { operation: "assign", input: parsed.data },
      normalizeCorrelationId(request.headers.get("x-correlation-id")),
    );
    if (result.error) return actionItemRpcErrorResponse(result.error);
    return NextResponse.json(result.data, {
      headers: { "Cache-Control": "private, no-store, max-age=0" },
    });
  } catch (error) {
    return actionItemExceptionResponse(error);
  }
}
