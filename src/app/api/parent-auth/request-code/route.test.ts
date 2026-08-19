import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  after: vi.fn(),
  callbacks: [] as Array<() => unknown>,
  admin: vi.fn(),
  legacyRpc: vi.fn(),
  featureEnabled: vi.fn(),
  rateAllowed: vi.fn(),
  prepare: vi.fn(),
  authorize: vi.fn(),
  complete: vi.fn(),
  getLegacyTemplate: vi.fn(),
  renderLegacy: vi.fn(),
  renderV2: vi.fn(),
  sendLegacy: vi.fn(),
  sendV2: vi.fn(),
}));

vi.mock("next/server", async (importOriginal) => {
  const original = await importOriginal<typeof import("next/server")>();
  return { ...original, after: mocks.after };
});
vi.mock("@/lib/env", () => ({
  getServerEnv: () => ({
    APP_BASE_URL: "https://tenue.example",
    PARENT_TOKEN_PEPPER: "p".repeat(32),
  }),
}));
vi.mock("@/server/supabase/admin", () => ({
  getSupabaseAdminClient: mocks.admin,
}));
vi.mock("@/server/operations/feature-flags", () => ({
  isOperationalFeatureEnabled: mocks.featureEnabled,
}));
vi.mock("@/server/auth/rate-limit", () => ({
  consumeRateLimit: mocks.rateAllowed,
  requestRateKey: () => "safe-rate-key",
}));
vi.mock("@/server/email/otp", () => ({
  prepareParentOtpV2: mocks.prepare,
  authorizeParentOtpV2: mocks.authorize,
  completeParentOtpV2: mocks.complete,
  getParentOtpEmailTemplate: mocks.getLegacyTemplate,
  renderParentOtpEmail: mocks.renderLegacy,
  renderParentOtpV2: mocks.renderV2,
}));
vi.mock("@/server/email/sendgrid", () => ({
  sendParentOtpEmail: mocks.sendLegacy,
}));
vi.mock("@/server/email/provider", () => ({ sendParentOtpV2Email: mocks.sendV2 }));

import { POST } from "./route";

const neutralBody = {
  message: "Als dit e-mailadres bij ons bekend is, is een code verzonden.",
};
const deliveryAttemptId = "11111111-1111-4111-8111-111111111111";
const message = {
  subject: "Uw verificatiecode",
  preheader: "Tien minuten geldig",
  text: "Eenmalige code",
  html: "<p>Eenmalige code</p>",
  fromName: "Kledingcommissie Duindorp SV",
  fromEmail: "kleding@duindorpsv.nl",
  replyToEmail: "kleding@duindorpsv.nl",
};

function request(email = "ouder@example.nl") {
  return new Request(
    "https://tenue.example/api/parent-auth/request-code",
    {
      method: "POST",
      headers: {
        "content-type": "application/json",
        origin: "https://tenue.example",
        host: "tenue.example",
        "sec-fetch-site": "same-origin",
        "x-duindorp-csrf": "same-origin",
      },
      body: JSON.stringify({ email }),
    },
  );
}

describe("POST /api/parent-auth/request-code", () => {
  beforeEach(() => {
    process.env.PARENT_TOKEN_PEPPER = "p".repeat(32);
    mocks.callbacks.length = 0;
    mocks.after.mockReset().mockImplementation(
      (callback: () => unknown) => {
        mocks.callbacks.push(callback);
      },
    );
    mocks.legacyRpc.mockReset().mockResolvedValue({
      data: "22222222-2222-4222-8222-222222222222",
      error: null,
    });
    const appClient = { rpc: vi.fn() };
    mocks.admin.mockReset().mockReturnValue({
      schema: () => appClient,
      rpc: mocks.legacyRpc,
    });
    mocks.featureEnabled.mockReset().mockResolvedValue(true);
    mocks.rateAllowed.mockReset().mockResolvedValue(true);
    mocks.prepare.mockReset().mockResolvedValue({
      status: "prepared",
      deliveryAttemptId,
    });
    mocks.authorize.mockReset().mockResolvedValue(true);
    mocks.complete.mockReset().mockResolvedValue({
      status: "completed",
      outcome: "accepted",
      reused: false,
    });
    mocks.getLegacyTemplate.mockReset().mockResolvedValue({});
    mocks.renderLegacy.mockReset().mockReturnValue(message);
    mocks.renderV2.mockReset().mockReturnValue(message);
    mocks.sendLegacy.mockReset().mockResolvedValue({ delivered: true });
    mocks.sendV2.mockReset().mockResolvedValue({
      delivered: true,
      providerMessageId: "otp-http-message-1",
    });
  });

  it("antwoordt neutraal vóór de providercall en levert daarna attempt-gebonden", async () => {
    const response = await POST(request());
    expect(response.status).toBe(202);
    expect(await response.json()).toEqual(neutralBody);
    expect(response.headers.get("set-cookie")).toContain(
      "duindorp_parent_challenge=",
    );
    expect(mocks.sendV2).not.toHaveBeenCalled();
    expect(mocks.callbacks).toHaveLength(1);

    await mocks.callbacks[0]();
    expect(mocks.authorize).toHaveBeenCalledWith(
      expect.anything(),
      deliveryAttemptId,
    );
    expect(mocks.sendV2).toHaveBeenCalledWith({
      deliveryAttemptId,
      recipientEmail: "ouder@example.nl",
      subject: message.subject,
      text: message.text,
      html: message.html,
      fromName: message.fromName,
      fromEmail: message.fromEmail,
      replyToEmail: message.replyToEmail,
    });
    expect(mocks.sendV2.mock.calls[0]?.[0]).not.toHaveProperty(
      "preheader",
    );
    expect(mocks.complete).toHaveBeenCalledWith(
      expect.anything(),
      deliveryAttemptId,
      {
        outcome: "accepted",
        providerMessageId: "otp-http-message-1",
      },
    );
  });

  it.each(["ineligible", "blocked"] as const)(
    "geeft voor interne status %s exact hetzelfde neutrale antwoord",
    async (status) => {
      mocks.prepare.mockResolvedValueOnce({ status });
      const response = await POST(request());
      expect(response.status).toBe(202);
      expect(await response.json()).toEqual(neutralBody);
      expect(mocks.sendV2).not.toHaveBeenCalled();
      expect(mocks.sendLegacy).not.toHaveBeenCalled();
      await mocks.callbacks[0]();
      expect(mocks.sendV2).not.toHaveBeenCalled();
      expect(mocks.sendLegacy).not.toHaveBeenCalled();
    },
  );

  it("gebruikt legacy uitsluitend vóór het v2-cutover en eveneens na de respons", async () => {
    mocks.prepare.mockResolvedValueOnce({ status: "unavailable" });
    const response = await POST(request());
    expect(response.status).toBe(202);
    expect(await response.json()).toEqual(neutralBody);
    expect(mocks.sendLegacy).not.toHaveBeenCalled();
    await mocks.callbacks[0]();
    expect(mocks.legacyRpc).toHaveBeenCalledWith(
      "create_parent_otp",
      expect.objectContaining({
        p_email: "ouder@example.nl",
      }),
    );
    expect(mocks.sendLegacy).toHaveBeenCalledWith(
      "ouder@example.nl",
      message,
    );
  });

  it("redigeert ook een voorbereiding- of databasefout naar dezelfde 202", async () => {
    mocks.prepare.mockRejectedValueOnce(
      new Error("database details of persoonsgegevens"),
    );
    const response = await POST(request());
    expect(response.status).toBe(202);
    expect(await response.json()).toEqual(neutralBody);
    expect(mocks.sendV2).not.toHaveBeenCalled();
    expect(mocks.sendLegacy).not.toHaveBeenCalled();
  });
});
