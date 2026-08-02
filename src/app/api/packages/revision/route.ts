import { NextResponse } from "next/server";
import { packageCloneRequestSchema } from "@/lib/package-contract";
import { packageMutationExceptionResponse, packageRpcErrorResponse } from "@/server/packages/http";
import { clonePackageRevision } from "@/server/packages/workspace";
import { normalizeCorrelationId } from "@/server/security/correlation";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonStandard });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonStandard);
  if (!body.ok) return body.response;
  const parsed = packageCloneRequestSchema.safeParse(body.data);
  if (!parsed.success) return NextResponse.json({ error: "Ongeldige pakketselectie." }, { status: 400 });
  try {
    const result = await clonePackageRevision(
      parsed.data.templateId,
      parsed.data.sourceRevisionId,
      parsed.data.expectedHash,
      normalizeCorrelationId(request.headers.get("x-correlation-id")),
    );
    if (result.error) return packageRpcErrorResponse(result.error);
    return NextResponse.json(result.data, { status: 201 });
  } catch (error) {
    return packageMutationExceptionResponse(error);
  }
}
