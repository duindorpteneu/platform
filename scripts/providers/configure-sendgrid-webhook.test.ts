import { generateKeyPairSync } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
// @ts-expect-error The production entrypoint is intentionally plain Node.js ESM.
import { configureSendGridWebhook } from "./configure-sendgrid-webhook.mjs";

const webhookId = "fd290462-a274-4899-82bd-4777cc382bae";
const webhookUrl = "https://staging-duindorp.dgwebservices.nl/api/webhooks/sendgrid";
const { publicKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const encodedPublicKey = publicKey.export({ type: "spki", format: "der" }).toString("base64");
const settings = {
  id: webhookId,
  enabled: true,
  url: webhookUrl,
  delivered: true,
  bounce: true,
  deferred: true,
  dropped: true,
  processed: false,
  spam_report: false,
  unsubscribe: false,
  group_unsubscribe: false,
  group_resubscribe: false,
  open: false,
  click: false,
  account_status_change: false,
};

function response(body: unknown) {
  return new Response(JSON.stringify(body), { status: 200, headers: { "Content-Type": "application/json" } });
}

describe("SendGrid webhook configurator", () => {
  it("configures and verifies the exact EU staging webhook without logging provider data", async () => {
    const providerSettings = { ...settings } as Record<string, unknown>;
    delete providerSettings.account_status_change;
    delete providerSettings.group_resubscribe;
    const fetchImpl = vi.fn()
      .mockResolvedValueOnce(response(settings))
      .mockResolvedValueOnce(response({ id: webhookId, public_key: encodedPublicKey }))
      .mockResolvedValueOnce(response(providerSettings))
      .mockResolvedValueOnce(response({ id: webhookId, public_key: encodedPublicKey }));

    await expect(configureSendGridWebhook({
      apiKey: "SG.test-key",
      apiBaseUrl: "https://api.eu.sendgrid.com",
      webhookId,
      webhookUrl,
      fetchImpl,
    })).resolves.toEqual({ publicKey: encodedPublicKey });

    expect(fetchImpl).toHaveBeenNthCalledWith(1,
      `https://api.eu.sendgrid.com/v3/user/webhooks/event/settings/${webhookId}`,
      expect.objectContaining({ method: "PATCH", body: expect.stringContaining('"delivered":true') }),
    );
    expect(fetchImpl).toHaveBeenNthCalledWith(2,
      `https://api.eu.sendgrid.com/v3/user/webhooks/event/settings/signed/${webhookId}`,
      expect.objectContaining({ method: "PATCH", body: '{"enabled":true}' }),
    );
  });

  it("fails closed on a wrong callback URL, engagement events or invalid signing key", async () => {
    const wrongSettings = { ...settings, url: "https://example.invalid/api/webhooks/sendgrid", open: true };
    const fetchImpl = vi.fn()
      .mockResolvedValueOnce(response(settings))
      .mockResolvedValueOnce(response({ id: webhookId, public_key: encodedPublicKey }))
      .mockResolvedValueOnce(response(wrongSettings));
    await expect(configureSendGridWebhook({
      apiKey: "SG.test-key", apiBaseUrl: "https://api.eu.sendgrid.com", webhookId, webhookUrl, fetchImpl,
    })).rejects.toThrow("SENDGRID_WEBHOOK_SETTINGS_INVALID");

    await expect(configureSendGridWebhook({
      apiKey: "SG.test-key", apiBaseUrl: "https://api.eu.sendgrid.com", webhookId,
      webhookUrl: "http://staging-duindorp.dgwebservices.nl/api/webhooks/sendgrid", fetchImpl,
    })).rejects.toThrow("SENDGRID_WEBHOOK_URL_INVALID");
  });
});
