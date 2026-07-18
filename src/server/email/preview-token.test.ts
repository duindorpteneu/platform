import { describe, expect, it } from "vitest";
import { createEmailPreviewToken, verifyEmailPreviewToken } from "@/server/email/preview-token";

const pepper = "email-preview-test-pepper-with-32-characters";
const order = "10000000-0000-4000-8000-000000000001";

describe("bulkmail previewtoken", () => {
  it("binds template, sorted orders and a ten minute expiry", () => {
    const token = createEmailPreviewToken("payment_reminder", [order, order], pepper, 1000);
    const payload = verifyEmailPreviewToken(token, pepper, 2000);
    expect(payload.orderIds).toEqual([order]);
    expect(payload.expiresAt).toBe(601000);
  });

  it("rejects tampering and expiry", () => {
    const token = createEmailPreviewToken("payment_reminder", [order], pepper, 1000);
    expect(() => verifyEmailPreviewToken(`${token}x`, pepper, 2000)).toThrow();
    expect(() => verifyEmailPreviewToken(token, pepper, 700000)).toThrow("EMAIL_PREVIEW_TOKEN_EXPIRED");
  });
});
