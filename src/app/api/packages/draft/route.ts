import { NextResponse } from "next/server";
import { packageDraftRequestSchema } from "@/lib/package-contract";
import { packageMutationExceptionResponse, packageRpcErrorResponse } from "@/server/packages/http";
import { savePackageDraft } from "@/server/packages/workspace";
import { normalizeCorrelationId } from "@/server/security/correlation";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonMedium });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonMedium);
  if (!body.ok) return body.response;
  const parsed = packageDraftRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return NextResponse.json({ error: "Controleer seizoen, pakketcode, naam, prijs en producten." }, { status: 400 });
  }
  try {
    const result = await savePackageDraft(
      parsed.data,
      normalizeCorrelationId(request.headers.get("x-correlation-id")),
    );
    if (result.error) return packageRpcErrorResponse(result.error);
    return NextResponse.json(result.data, { status: result.data.created ? 201 : 200 });
  } catch (error) {
    return packageMutationExceptionResponse(error);
  }
}
