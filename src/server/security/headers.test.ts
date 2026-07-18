import { describe, expect, it } from "vitest";
import { buildContentSecurityPolicy, buildSecurityHeaders } from "./headers";

describe("production security headers", () => {
  it("sets the complete browser hardening baseline", () => {
    const headers = Object.fromEntries(buildSecurityHeaders(true, "https://project.supabase.co/rest/v1").map(({ key, value }) => [key, value]));
    expect(headers).toMatchObject({
      "Cross-Origin-Opener-Policy": "same-origin",
      "Cross-Origin-Resource-Policy": "same-origin",
      "Referrer-Policy": "strict-origin-when-cross-origin",
      "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
      "X-Content-Type-Options": "nosniff",
      "X-Frame-Options": "DENY",
    });
    expect(headers["Permissions-Policy"]).toContain("camera=(self)");
  });

  it("pins CSP to self and the configured Supabase HTTPS/WSS origins", () => {
    const policy = buildContentSecurityPolicy(true, "https://project.supabase.co/rest/v1");
    for (const directive of ["base-uri 'self'", "form-action 'self'", "frame-ancestors 'none'", "object-src 'none'", "upgrade-insecure-requests"]) {
      expect(policy).toContain(directive);
    }
    expect(policy).toContain("connect-src 'self' https://project.supabase.co wss://project.supabase.co");
    expect(policy).not.toContain("'unsafe-eval'");
  });

  it("allows the Next.js development evaluator without sending HSTS locally", () => {
    expect(buildContentSecurityPolicy(false)).toContain("'unsafe-eval'");
    expect(buildSecurityHeaders(false).some(({ key }) => key === "Strict-Transport-Security")).toBe(false);
  });

  it("ignores invalid provider origins", () => {
    expect(buildContentSecurityPolicy(true, "javascript:alert(1)")).toContain("connect-src 'self'");
    expect(buildContentSecurityPolicy(true, "javascript:alert(1)")).not.toContain("javascript:");
  });
});
