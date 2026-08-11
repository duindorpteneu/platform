import { createHash } from "node:crypto";
import {
  describe,
  expect,
  it,
  vi,
} from "vitest";
// @ts-expect-error The provider entrypoint is intentionally plain Node.js ESM.
import { validateSendGridFingerprintConfig, verifySendGridFingerprints } from "./verify-sendgrid-fingerprints.mjs";

const appKey = "SG.mail-send-only";
const adminKey = "SG.webhook-admin";
const identity = {
  username: "duindorp-staging",
  user_id: 12345,
};
const hash = (value: string) => createHash("sha256")
  .update(value)
  .digest("hex");
const values = {
  SENDGRID_API_BASE_URL: "https://api.eu.sendgrid.com",
  SENDGRID_API_KEY: appKey,
  SENDGRID_ADMIN_API_KEY: adminKey,
  SENDGRID_API_KEY_FINGERPRINT: hash(appKey),
  SENDGRID_EXPECTED_ACCOUNT_FINGERPRINT: hash(
    `${identity.username}:${identity.user_id}`,
  ),
};
const adminScopes = [
  "user.username.read",
  "user.webhooks.event.settings.read",
  "user.webhooks.event.settings.update",
];

function response(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

describe("SendGrid fingerprint verification", () => {
  it("uses the configured region and verifies account plus minimal key scope", async () => {
    const fetchImpl = vi.fn()
      .mockResolvedValueOnce(response(identity))
      .mockResolvedValueOnce(response({ scopes: ["mail.send"] }))
      .mockResolvedValueOnce(response({
        scopes: [...adminScopes].reverse(),
      }));

    await expect(verifySendGridFingerprints(
      values,
      fetchImpl,
    )).resolves.toBeUndefined();
    expect(fetchImpl).toHaveBeenNthCalledWith(
      1,
      "https://api.eu.sendgrid.com/v3/user/username",
      expect.objectContaining({
        headers: { Authorization: `Bearer ${adminKey}` },
      }),
    );
    expect(fetchImpl).toHaveBeenNthCalledWith(
      2,
      "https://api.eu.sendgrid.com/v3/scopes",
      expect.objectContaining({
        headers: { Authorization: `Bearer ${appKey}` },
      }),
    );
    expect(fetchImpl).toHaveBeenNthCalledWith(
      3,
      "https://api.eu.sendgrid.com/v3/scopes",
      expect.objectContaining({
        headers: { Authorization: `Bearer ${adminKey}` },
      }),
    );
  });

  it("fails before any provider call for a wrong app-key fingerprint", async () => {
    const fetchImpl = vi.fn();
    await expect(verifySendGridFingerprints({
      ...values,
      SENDGRID_API_KEY_FINGERPRINT: "0".repeat(64),
    }, fetchImpl)).rejects.toThrow(
      "SENDGRID_API_KEY_FINGERPRINT_MISMATCH",
    );
    expect(fetchImpl).not.toHaveBeenCalled();
  });

  it("fails closed for another account, excess scopes or an unsafe endpoint", async () => {
    await expect(verifySendGridFingerprints(
      values,
      vi.fn().mockResolvedValueOnce(response({
        username: "other-account",
        user_id: 999,
      })),
    )).rejects.toThrow("SENDGRID_ACCOUNT_IDENTITY_MISMATCH");

    await expect(verifySendGridFingerprints(
      values,
      vi.fn()
        .mockResolvedValueOnce(response(identity))
        .mockResolvedValueOnce(response({
          scopes: ["mail.send", "user.profile.read"],
        })),
    )).rejects.toThrow("SENDGRID_APP_KEY_SCOPE_NOT_MINIMAL");

    await expect(verifySendGridFingerprints(
      values,
      vi.fn()
        .mockResolvedValueOnce(response(identity))
        .mockResolvedValueOnce(response({ scopes: ["mail.send"] }))
        .mockResolvedValueOnce(response({
          scopes: [...adminScopes, "mail.send"],
        })),
    )).rejects.toThrow("SENDGRID_ADMIN_KEY_SCOPE_NOT_MINIMAL");

    expect(() => validateSendGridFingerprintConfig({
      ...values,
      SENDGRID_API_BASE_URL:
        "https://api.sendgrid.com.example.invalid",
    })).toThrow("SENDGRID_FINGERPRINT_CONFIG_INVALID");
  });

  it("never includes provider response data in HTTP errors", async () => {
    await expect(verifySendGridFingerprints(
      values,
      vi.fn().mockResolvedValueOnce(response({
        errors: [{ message: "provider detail" }],
      }, 401)),
    )).rejects.toThrow("SENDGRID_PROVIDER_HTTP_401");
  });

  it("rejects malformed provider identity fields", async () => {
    for (const malformedIdentity of [
      { username: "  ", user_id: 12345 },
      { username: "duindorp staging", user_id: 12345 },
      { username: "duindorp-staging", user_id: "" },
      { username: "duindorp-staging", user_id: 0 },
    ]) {
      await expect(verifySendGridFingerprints(
        values,
        vi.fn().mockResolvedValueOnce(response(malformedIdentity)),
      )).rejects.toThrow("SENDGRID_ACCOUNT_IDENTITY_INVALID");
    }
  });
});
