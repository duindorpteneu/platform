import { createServerClient, type CookieOptions } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { getServerEnv } from "@/lib/env";
import { CORRELATION_ID_HEADER, resolveCorrelationId, withCorrelationId } from "@/server/security/correlation";

function correlatedResponse(response: NextResponse, correlationId: string) {
  response.headers.set(CORRELATION_ID_HEADER, correlationId);
  return response;
}

function privateResponse(response: NextResponse, correlationId: string) {
  response.headers.set("Cache-Control", "private, no-store, max-age=0");
  return correlatedResponse(response, correlationId);
}

function redirectUrl(request: NextRequest, path: string) {
  const rawForwardedHost = request.headers.get("x-forwarded-host");
  const forwardedHost = rawForwardedHost && !rawForwardedHost.includes(",") ? rawForwardedHost : null;
  const host = (forwardedHost ?? request.headers.get("host"))?.trim().toLowerCase();
  const forwardedProto = request.headers.get("x-forwarded-proto")?.trim().toLowerCase();
  const protocol = forwardedProto === "https" || forwardedProto === "http"
    ? forwardedProto
    : request.nextUrl.protocol.replace(":", "");
  if (!host || !/^[a-z0-9.-]+(?::\d{1,5})?$/.test(host) || !["http", "https"].includes(protocol)) {
    throw new Error("INVALID_REQUEST_ORIGIN");
  }
  return new URL(path, `${protocol}://${host}`);
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
  const staffSurface = request.nextUrl.pathname.startsWith("/backoffice") || request.nextUrl.pathname.startsWith("/uitgifte");
  if (!staffSurface) return correlatedResponse(nextResponse(), correlationId);

  const env = getServerEnv();
  if (!env.NEXT_PUBLIC_SUPABASE_URL || !env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY) {
    return redirectWithCookies(request, "/staff/login", correlationId);
  }

  let response = nextResponse();
  const supabase = createServerClient(env.NEXT_PUBLIC_SUPABASE_URL, env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, {
    cookies: {
      getAll() { return request.cookies.getAll(); },
      setAll(cookiesToSet: { name: string; value: string; options: CookieOptions }[]) {
        cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
        response = nextResponse();
        cookiesToSet.forEach(({ name, value, options }) => response.cookies.set(name, value, options));
      },
    },
  });

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return redirectWithCookies(request, "/staff/login", correlationId, response);

  const { data: assurance, error: assuranceError } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
  if (assuranceError || assurance?.currentLevel !== "aal2") {
    return redirectWithCookies(request, "/staff/mfa", correlationId, response);
  }

  const { data: profile } = await supabase.schema("app").from("staff_profiles").select("role, active").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!profile) return redirectWithCookies(request, "/staff/login", correlationId, response);
  if (profile.role === "uitgifte" && request.nextUrl.pathname.startsWith("/backoffice")) {
    return redirectWithCookies(request, "/uitgifte", correlationId, response);
  }
  return privateResponse(response, correlationId);
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
