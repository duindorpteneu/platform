import { NextResponse } from "next/server";
import { packageArchiveRequestSchema } from "@/lib/package-contract";
import { packageMutationExceptionResponse, packageRpcErrorResponse } from "@/server/packages/http";
import { archivePackageRevision } from "@/server/packages/workspace";
import { normalizeCorrelationId } from "@/server/security/correlation";
import { BODY_POLICIES, guardBrowserMutation, readJsonRequest } from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, { body: BODY_POLICIES.jsonStandard });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonStandard);
  if (!body.ok) return body.response;
  const parsed = packageArchiveRequestSchema.safeParse(body.data);
  if (!parsed.success) return NextResponse.json({ error: "Geef een geldige archiveringsreden op." }, { status: 400 });
  try {
    const result = await archivePackageRevision(
      parsed.data.revisionId,
      parsed.data.reason,
      parsed.data.expectedHash,
      normalizeCorrelationId(request.headers.get("x-correlation-id")),
    );
    if (result.error) return packageRpcErrorResponse(result.error);
    return NextResponse.json(result.data);
  } catch (error) {
    return packageMutationExceptionResponse(error);
  }
}
