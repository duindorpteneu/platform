import { NextResponse } from "next/server";
import { supplierLoginRequestSchema } from "@/lib/supplier-contract";
import { getSupplierContext } from "@/server/auth/supplier";
import {
  createSupplierSession,
  SUPPLIER_SESSION_COOKIE,
} from "@/server/auth/supplier-context";
import {
  BODY_POLICIES,
  guardBrowserMutation,
  readJsonRequest,
} from "@/server/security/route-guard";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
const privateHeaders = { "Cache-Control": "private, no-store, max-age=0" };

function requestKey(request: Request) {
  const forwarded = request.headers.get("x-forwarded-for")
    ?.split(",", 1)[0]
    ?.trim();
  return request.headers.get("x-real-ip")?.trim()
    || forwarded
    || "unknown";
}

export async function GET() {
  const supplier = await getSupplierContext();
  if (!supplier) {
    return NextResponse.json(
      { error: "SUPPLIER_ACCESS_REQUIRED" },
      { status: 403, headers: privateHeaders },
    );
  }
  return NextResponse.json(
    { landingPath: "/leverancier" },
    { headers: privateHeaders },
  );
}

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, {
    body: BODY_POLICIES.jsonTiny,
  });
  if (guarded) return guarded;
  const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
  if (!body.ok) return body.response;
  const parsed = supplierLoginRequestSchema.safeParse(body.data);
  if (!parsed.success) {
    return NextResponse.json(
      { error: "SUPPLIER_ACCESS_REJECTED" },
      { status: 403, headers: privateHeaders },
    );
  }

  try {
    const created = await createSupplierSession(
      parsed.data.accessToken,
      requestKey(request),
    );
    if (!created) {
      return NextResponse.json(
        { error: "SUPPLIER_ACCESS_REJECTED" },
        { status: 403, headers: privateHeaders },
      );
    }
    const response = NextResponse.json(
      { landingPath: "/leverancier" },
      { headers: privateHeaders },
    );
    response.cookies.set(
      SUPPLIER_SESSION_COOKIE,
      created.sessionToken,
      {
        httpOnly: true,
        secure: process.env.NODE_ENV === "production",
        sameSite: "lax",
        path: "/",
        maxAge: 8 * 60 * 60,
      },
    );
    return response;
  } catch {
    return NextResponse.json(
      { error: "SUPPLIER_ACCESS_UNAVAILABLE" },
      { status: 503, headers: privateHeaders },
    );
  }
}
