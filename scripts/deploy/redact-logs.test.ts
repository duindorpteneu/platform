import { describe, expect, it } from "vitest";
// @ts-expect-error Plain Node.js streaming helper without declaration file.
import { redactLine } from "./redact-logs.mjs";

describe("deployment log redaction", () => {
  const values = {
    SENDGRID_API_KEY: "SG.secret-value",
    SENDGRID_SMOKE_RECIPIENT: "acceptance@duindorpsv.invalid",
    E2E_MAILBOX_IMAP_PASSWORD: "mailbox-password",
  };

  it.each([
    "postgresql://operator:password@database.invalid:5432/postgres?sslmode=require",
    "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.signature",
    "authorization=Basic YWxhZGRpbjpvcGVuc2VzYW1l",
    "https://example.invalid/callback?token=secret-token&code=123456",
    "Mail voor persoon@example.nl",
    "Provider SG.secret-value mailbox-password acceptance@duindorpsv.invalid",
    "Cookie: duindorp_staff_session=session-secret; Path=/",
    "Set-Cookie=duindorp_parent_session=parent-secret; HttpOnly",
    "locator q2.k1.ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi",
    "grant sg2.k21.ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi",
    "jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signaturevalue",
    "SendGrid SG.abcdefghijklmnopqrstuvwxyz0123456789",
    "otp=918273 verification_code: 827364 code: 736251",
  ])("redacts sensitive log content without reproducing it: %s", (line) => {
    const result = redactLine(line, values);
    expect(result).toContain("[REDACTED");
    expect(result).not.toContain("password");
    expect(result).not.toContain("secret-token");
    expect(result).not.toContain("123456");
    expect(result).not.toContain("@");
    expect(result).not.toContain("eyJ");
    expect(result).not.toContain("duindorp_staff_session");
    expect(result).not.toContain("q2.k");
    expect(result).not.toContain("sg2.k");
    expect(result).not.toContain("918273");
  });

  it("preserves operationally useful non-sensitive diagnostics", () => {
    expect(redactLine(
      "POST /api/internal/jobs/email gaf HTTP 503 na 1200ms",
      values,
    )).toBe("POST /api/internal/jobs/email gaf HTTP 503 na 1200ms");
  });
});
