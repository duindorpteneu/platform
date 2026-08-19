import { NextResponse } from "next/server";
import {
  BODY_POLICIES,
  guardBrowserMutation,
  readJsonRequest,
} from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const privateHeaders = { "Cache-Control": "private, no-store, max-age=0" };

/**
 * Ouders kiezen of wisselen geen commercieel pakket. Een beheerder maakt de
 * expliciete, geauditeerde pakkettoewijzing; deze oude endpoint blijft alleen
 * bestaan om oudere clients veilig en zonder mutatie af te wijzen.
 */
export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, {
    body: BODY_POLICIES.jsonTiny,
  });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
  if (!body.ok) return body.response;
  return NextResponse.json(
    {
      error: "Alleen de beheerder kan een kledingpakket toewijzen of wijzigen.",
    },
    { status: 403, headers: privateHeaders },
  );
}
