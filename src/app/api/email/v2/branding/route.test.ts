import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  publish: vi.fn(),
  save: vi.fn(),
}));
vi.mock("@/server/email/mail-v2-workspace", () => ({
  publishMailV2Branding: mocks.publish,
  saveMailV2BrandingDraft: mocks.save,
}));

import { POST } from "./route";

const revisionId = "67000000-0000-4000-8000-000000000001";
const contentHash = "b".repeat(64);
const correlationId = "67000000-0000-4000-8000-000000000002";
const branding = {
  action: "save" as const,
  expectedHash: null,
  clubName: "Duindorp SV" as const,
  logoAssetPath: "/duindorp-sv-logo.png" as const,
  fromName: "Kledingcommissie Duindorp SV",
  fromEmail: "kleding@duindorpsv.nl",
  replyToEmail: "kleding@duindorpsv.nl",
  contactEmail: "kleding@duindorpsv.nl",
  clubAddressLine: "Houtrustlaan 1",
  clubPostalCode: "2566 ZW",
  clubCity: "Den Haag",
  pickupName: "Free-Kick Sport",
  pickupAddressLine: "De Savornin Lohmanplein 45",
  pickupPostalCode: "2566 AE",
  pickupCity: "Den Haag",
  privacyUrl: "https://duindorpsv.nl/privacy" as const,
  primaryColor: "#17418B",
  secondaryColor: "#0B2E63",
  accentColor: "#2E69CC",
  footerText: "Duindorp SV kledingcommissie",
};

function request(body: unknown) {
  return new Request("https://tenue.example/api/email/v2/branding", {
    method: "POST",
    headers: {
      origin: "https://tenue.example",
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
      "x-correlation-id": correlationId,
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

describe("POST /api/email/v2/branding", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.save.mockReset().mockResolvedValue({
      data: { revisionId, revision: 2, status: "draft", contentHash },
      error: null,
    });
    mocks.publish.mockReset().mockResolvedValue({
      data: { revisionId, revision: 2, status: "published", contentHash },
      error: null,
    });
  });

  it("behoudt de vaste clubidentiteit en stuurt operationele branding strikt door", async () => {
    const response = await POST(request(branding));
    expect(response.status).toBe(200);
    expect(mocks.save).toHaveBeenCalledWith(
      branding,
      correlationId,
    );
  });

  it("weigert headerinjectie en een gewijzigd privacyadres vóór de service", async () => {
    const injected = await POST(request({
      ...branding,
      fromName: "Duindorp\r\nBcc: iemand@example.invalid",
    }));
    expect(injected.status).toBe(400);

    const changedIdentity = await POST(request({
      ...branding,
      privacyUrl: "https://evil.invalid/privacy",
    }));
    expect(changedIdentity.status).toBe(400);
    expect(mocks.save).not.toHaveBeenCalled();
  });

  it("vertaalt onvoldoende MFA naar 403 en contrastblokkade naar 422", async () => {
    mocks.publish.mockRejectedValueOnce(new Error("STAFF_AUTHORIZATION_REQUIRED"));
    const denied = await POST(request({
      action: "publish",
      revisionId,
      expectedHash: contentHash,
    }));
    expect(denied.status).toBe(403);

    mocks.publish.mockResolvedValueOnce({
      data: null,
      error: { code: "23514", message: "interne validatiecontext" },
    });
    const contrast = await POST(request({
      action: "publish",
      revisionId,
      expectedHash: contentHash,
    }));
    expect(contrast.status).toBe(422);
    expect(await contrast.text()).not.toContain("interne validatiecontext");
  });
});
