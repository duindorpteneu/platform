import { NextResponse } from "next/server";
import { packagePublishRequestSchema } from "@/lib/package-contract";
import { packageMutationExceptionResponse, packageRpcErrorResponse } from "@/server/packages/http";
import { publishPackageRevision } from "@/server/packages/workspace";
import { normalizeCorrelationId } from "@/server/security/correlation";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonStandard });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonStandard);
  if (!body.ok) return body.response;
  const parsed = packagePublishRequestSchema.safeParse(body.data);
  if (!parsed.success) return NextResponse.json({ error: "Ongeldige pakketpublicatie." }, { status: 400 });
  try {
    const result = await publishPackageRevision(
      parsed.data.revisionId,
      parsed.data.makeDefault,
      parsed.data.expectedHash,
      normalizeCorrelationId(request.headers.get("x-correlation-id")),
    );
    if (result.error) return packageRpcErrorResponse(result.error);
    return NextResponse.json(result.data);
  } catch (error) {
    return packageMutationExceptionResponse(error);
  }
}
