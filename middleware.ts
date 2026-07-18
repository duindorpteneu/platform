import { createServerClient, type CookieOptions } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { getServerEnv } from "@/lib/env";

function privateResponse(response: NextResponse) {
  response.headers.set("Cache-Control", "private, no-store, max-age=0");
  return response;
}

function redirectWithCookies(url: URL, response?: NextResponse) {
  const redirect = NextResponse.redirect(url);
  response?.cookies.getAll().forEach((cookie) => redirect.cookies.set(cookie));
  return privateResponse(redirect);
}

export async function middleware(request: NextRequest) {
  const env = getServerEnv();
  if (!env.NEXT_PUBLIC_SUPABASE_URL || !env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY) {
    return redirectWithCookies(new URL("/staff/login", request.url));
  }

  let response = NextResponse.next({ request });
  const supabase = createServerClient(env.NEXT_PUBLIC_SUPABASE_URL, env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, {
    cookies: {
      getAll() { return request.cookies.getAll(); },
      setAll(cookiesToSet: { name: string; value: string; options: CookieOptions }[]) {
        cookiesToSet.forEach(({ name, value, options }) => {
          request.cookies.set(name, value);
          response = NextResponse.next({ request });
          response.cookies.set(name, value, options);
        });
      },
    },
  });

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return redirectWithCookies(new URL("/staff/login", request.url), response);

  const { data: assurance, error: assuranceError } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
  if (assuranceError || assurance?.currentLevel !== "aal2") {
    return redirectWithCookies(new URL("/staff/mfa", request.url), response);
  }

  const { data: profile } = await supabase.schema("app").from("staff_profiles").select("role, active").eq("auth_user_id", user.id).eq("active", true).maybeSingle();
  if (!profile) return redirectWithCookies(new URL("/staff/login", request.url), response);
  if (profile.role === "uitgifte" && request.nextUrl.pathname.startsWith("/backoffice")) {
    return redirectWithCookies(new URL("/uitgifte", request.url), response);
  }
  return privateResponse(response);
}

export const config = {
  matcher: ["/backoffice/:path*", "/uitgifte/:path*"],
};
