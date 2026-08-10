import { NextResponse } from "next/server";
import { applyMemberSavedViewRequestSchema } from "@/lib/member-overview-contract";
import {
  applyMemberSavedView,
  type MemberSavedViewRpcError,
} from "@/server/members/saved-views";
import {
  BODY_POLICIES,
  guardBrowserMutation,
  readJsonRequest,
} from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const headers = { "Cache-Control": "private, no-store, max-age=0" };

function rpcError(error: MemberSavedViewRpcError) {
  if (error.code === "42501") {
    return NextResponse.json(
      { error: "Geen toegang tot deze opgeslagen weergave." },
      { status: 403, headers },
    );
  }
  if (error.code === "P0002") {
    return NextResponse.json(
      { error: "Deze opgeslagen weergave bestaat niet meer." },
      { status: 404, headers },
    );
  }
  if (error.code === "23514") {
    return NextResponse.json(
      { error: "Deze weergave bevat verouderde filters en is niet toegepast." },
      { status: 409, headers },
    );
  }
  return NextResponse.json(
    { error: "De opgeslagen weergave kon niet veilig worden toegepast." },
    { status: 422, headers },
  );
}

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, {
    body: BODY_POLICIES.jsonTiny,
  });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
  if (!body.ok) return body.response;
  const parsed = applyMemberSavedViewRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Controleer de opgeslagen weergave en het seizoen." },
      { status: 400, headers },
    );
  }

  try {
    const result = await applyMemberSavedView(parsed.data);
    if (result.error) return rpcError(result.error);
    return NextResponse.json(result.data, { headers });
  } catch (error) {
    if (
      error instanceof Error
      && error.message === "STAFF_AUTHORIZATION_REQUIRED"
    ) {
      return NextResponse.json(
        { error: "Geen toegang tot deze opgeslagen weergave." },
        { status: 403, headers },
      );
    }
    return NextResponse.json(
      { error: "Opgeslagen ledenweergaven zijn tijdelijk niet beschikbaar." },
      { status: 503, headers },
    );
  }
}
