import { NextResponse, type NextRequest } from "next/server";
import { getServerEnv } from "@/lib/env";
import { fetchStaffContext, STAFF_SESSION_COOKIE } from "@/server/auth/staff-context";
import {
  fetchSupplierContext,
  SUPPLIER_SESSION_COOKIE,
} from "@/server/auth/supplier-context";
import { CORRELATION_ID_HEADER, resolveCorrelationId, withCorrelationId } from "@/server/security/correlation";

function correlatedResponse(response: NextResponse, correlationId: string) {
  response.headers.set(CORRELATION_ID_HEADER, correlationId);
  return response;
}

function privateResponse(response: NextResponse, correlationId: string) {
  response.headers.set("Cache-Control", "private, no-store, max-age=0");
  return correlatedResponse(response, correlationId);
}

function redirectUrl(_request: NextRequest, path: string) {
  return new URL(path, getServerEnv().APP_BASE_URL);
}

function redirectWithCookies(request: NextRequest, path: string, correlationId: string, response?: NextResponse) {
  const redirect = NextResponse.redirect(redirectUrl(request, path));
  response?.cookies.getAll().forEach((cookie) => redirect.cookies.set(cookie));
  return privateResponse(redirect, correlationId);
}

export async function middleware(request: NextRequest) {
  const correlationId = resolveCorrelationId(request.headers.get(CORRELATION_ID_HEADER));
  const requestHeaders = withCorrelationId(request.headers, correlationId);
  const nextResponse = () => NextResponse.next({ request: { headers: requestHeaders } });
  const publicScannerAsset = new Set([
    "/uitgifte/apple-touch-icon.png",
    "/uitgifte/icon-192.png",
    "/uitgifte/icon-512.png",
    "/uitgifte/manifest.webmanifest",
    "/uitgifte/scanner-sw.js",
  ]).has(request.nextUrl.pathname);
  if (publicScannerAsset) {
    return correlatedResponse(nextResponse(), correlationId);
  }
  const staffSurface = request.nextUrl.pathname.startsWith("/admin") || request.nextUrl.pathname.startsWith("/backoffice") || request.nextUrl.pathname.startsWith("/uitgifte");
  const supplierSurface = request.nextUrl.pathname === "/leverancier";
  if (supplierSurface) {
    const env = getServerEnv();
    if (!env.NEXT_PUBLIC_SUPABASE_URL || !env.SUPABASE_SECRET_KEY) {
      return redirectWithCookies(
        request,
        "/leverancier/login",
        correlationId,
      );
    }
    const response = nextResponse();
    const sessionToken = request.cookies.get(
      SUPPLIER_SESSION_COOKIE,
    )?.value;
    const supplier = sessionToken
      ? await fetchSupplierContext(sessionToken)
      : null;
    if (!supplier) {
      return redirectWithCookies(
        request,
        "/leverancier/login",
        correlationId,
        response,
      );
    }
    return privateResponse(response, correlationId);
  }
  if (!staffSurface) return correlatedResponse(nextResponse(), correlationId);

  const env = getServerEnv();
  if (!env.NEXT_PUBLIC_SUPABASE_URL || !env.SUPABASE_SECRET_KEY) {
    return redirectWithCookies(request, "/staff/login", correlationId);
  }

  const response = nextResponse();
  const sessionToken = request.cookies.get(STAFF_SESSION_COOKIE)?.value;
  if (!sessionToken) {
    const hasSupabaseCookie = request.cookies.getAll().some((cookie) => cookie.name.startsWith("sb-") && cookie.name.includes("auth-token"));
    return redirectWithCookies(request, hasSupabaseCookie ? "/staff/mfa" : "/staff/login", correlationId, response);
  }
  const staff = await fetchStaffContext(sessionToken);
  if (!staff) return redirectWithCookies(request, "/staff/login", correlationId, response);

  if (staff.role === "uitgifte" && (request.nextUrl.pathname.startsWith("/admin") || request.nextUrl.pathname.startsWith("/backoffice"))) {
    return redirectWithCookies(request, "/uitgifte", correlationId, response);
  }
  if (
    staff.role === "kledingcommissie"
    && request.nextUrl.pathname.startsWith("/uitgifte")
  ) {
    return redirectWithCookies(request, "/backoffice", correlationId, response);
  }
  return privateResponse(response, correlationId);
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
