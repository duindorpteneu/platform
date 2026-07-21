import { createServerClient, type CookieOptions } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { getServerEnv } from "@/lib/env";
import { staffContextSchema } from "@/lib/staff-auth-contract";
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
  const staffSurface = request.nextUrl.pathname.startsWith("/admin") || request.nextUrl.pathname.startsWith("/backoffice") || request.nextUrl.pathname.startsWith("/uitgifte");
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

  const { data, error } = await supabase.schema("app").rpc("get_staff_auth_context");
  const staff = staffContextSchema.safeParse(data);
  if (error || !staff.success) {
    const hasAuthCookie = request.cookies.getAll().some((cookie) => cookie.name.startsWith("sb-") && cookie.name.includes("auth-token"));
    return redirectWithCookies(request, hasAuthCookie ? "/staff/mfa" : "/staff/login", correlationId, response);
  }

  if (staff.data.role === "uitgifte" && (request.nextUrl.pathname.startsWith("/admin") || request.nextUrl.pathname.startsWith("/backoffice"))) {
    return redirectWithCookies(request, "/uitgifte", correlationId, response);
  }
  return privateResponse(response, correlationId);
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
