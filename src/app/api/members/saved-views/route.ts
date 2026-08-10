import { NextResponse } from "next/server";
import {
  deleteMemberSavedViewRequestSchema,
  saveMemberSavedViewRequestSchema,
} from "@/lib/member-overview-contract";
import {
  deleteMemberSavedView,
  saveMemberSavedView,
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
      { error: "Geen toegang tot opgeslagen ledenweergaven." },
      { status: 403, headers },
    );
  }
  if (error.code === "P0002") {
    return NextResponse.json(
      { error: "De opgeslagen weergave of het seizoen bestaat niet meer." },
      { status: 404, headers },
    );
  }
  if (error.code === "23505") {
    return NextResponse.json(
      { error: "Je hebt al een weergave met deze naam in dit seizoen." },
      { status: 409, headers },
    );
  }
  if (error.code === "23514") {
    return NextResponse.json(
      { error: "Een filter is verouderd. Vernieuw de ledenlijst en sla opnieuw op." },
      { status: 409, headers },
    );
  }
  if (error.code === "22023") {
    return NextResponse.json(
      { error: "De naam of filters zijn ongeldig." },
      { status: 400, headers },
    );
  }
  return NextResponse.json(
    { error: "De opgeslagen weergave kon niet veilig worden verwerkt." },
    { status: 422, headers },
  );
}

function exceptionResponse(error: unknown) {
  if (
    error instanceof Error
    && error.message === "STAFF_AUTHORIZATION_REQUIRED"
  ) {
    return NextResponse.json(
      { error: "Geen toegang tot opgeslagen ledenweergaven." },
      { status: 403, headers },
    );
  }
  return NextResponse.json(
    { error: "Opgeslagen ledenweergaven zijn tijdelijk niet beschikbaar." },
    { status: 503, headers },
  );
}

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, {
    body: BODY_POLICIES.jsonSmall,
  });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonSmall);
  if (!body.ok) return body.response;
  const parsed = saveMemberSavedViewRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Controleer naam, seizoen en filters." },
      { status: 400, headers },
    );
  }

  try {
    const result = await saveMemberSavedView(parsed.data);
    if (result.error) return rpcError(result.error);
    return NextResponse.json(result.data, { headers });
  } catch (error) {
    return exceptionResponse(error);
  }
}

export async function DELETE(request: Request) {
  const guarded = guardBrowserMutation(request, {
    body: BODY_POLICIES.jsonTiny,
  });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
  if (!body.ok) return body.response;
  const parsed = deleteMemberSavedViewRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "Controleer de opgeslagen weergave en het seizoen." },
      { status: 400, headers },
    );
  }

  try {
    const result = await deleteMemberSavedView(parsed.data);
    if (result.error) return rpcError(result.error);
    return NextResponse.json(result.data, { headers });
  } catch (error) {
    return exceptionResponse(error);
  }
}
