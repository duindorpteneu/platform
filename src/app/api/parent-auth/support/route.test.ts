import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  requireRole: vi.fn(),
  serverRpc: vi.fn(),
  adminRpc: vi.fn(),
  deliver: vi.fn(),
}));

vi.mock("@/lib/env", () => ({
  getServerEnv: () => ({ APP_BASE_URL: "https://tenue.example" }),
}));
vi.mock("@/server/auth/parent", () => ({
  generateParentChallengeId: () => "11111111-1111-4111-8111-111111111111",
  deriveParentCode: () => "123456",
  hashParentSecret: () => "c".repeat(64),
}));
vi.mock("@/server/auth/staff", () => ({
  requireStaffRole: mocks.requireRole,
}));
vi.mock("@/server/email/otp-delivery", () => ({
  deliverPreparedParentOtpV3: mocks.deliver,
}));
vi.mock("@/server/supabase/server", () => ({
  getSupabaseServerClient: async () => ({
    schema: () => ({ rpc: mocks.serverRpc }),
  }),
}));
vi.mock("@/server/supabase/admin", () => ({
  getSupabaseAdminClient: () => ({
    schema: () => ({ rpc: mocks.adminRpc }),
  }),
}));

import { POST } from "./route";

const parentAccountId = "44444444-4444-4444-8444-444444444444";
const challengeId = "11111111-1111-4111-8111-111111111111";
const deliveryAttemptId = "22222222-2222-4222-8222-222222222222";
const expiresAt = "2026-08-21T15:30:00.000Z";

const preparation = {
  status: "prepared",
  challengeId,
  expiresAt,
  cooldownUntil: "2026-08-21T15:21:30.000Z",
  reused: true,
  deliveryAttemptId,
  expiresInMinutes: 9,
  template: {
    id: "33333333-3333-4333-8333-333333333333",
    templateKey: "login_otp",
    subjectSource: "Uw code voor {{club_name}}",
    preheaderSource: "Gebruik de code binnen {{otp_expiry_minutes}} minuten.",
    bodyTipTap: {
      type: "doc",
      content: [
        { type: "protectedBlock", attrs: { kind: "otp_code" } },
        { type: "protectedBlock", attrs: { kind: "otp_validity" } },
        { type: "protectedBlock", attrs: { kind: "otp_direct_login" } },
        { type: "protectedBlock", attrs: { kind: "otp_warning" } },
      ],
    },
    contentHash: "a".repeat(64),
    allowedShortcodes: ["club_name", "otp_expiry_minutes"],
    allowedProtectedNodes: [
      "otp_code",
      "otp_validity",
      "otp_direct_login",
      "otp_warning",
    ],
    requiredProtectedNodes: [
      "otp_code",
      "otp_validity",
      "otp_direct_login",
      "otp_warning",
    ],
  },
  branding: {
    id: "55555555-5555-4555-8555-555555555555",
    clubName: "Duindorp SV",
    logoAssetPath: "/duindorp-sv-logo.png",
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
    privacyUrl: "https://duindorpsv.nl/privacy",
    primaryColor: "#0055A4",
    secondaryColor: "#003B73",
    accentColor: "#F2C94C",
    footerText: "Kledingcommissie Duindorp SV",
    contrastValidated: true,
    contentHash: "b".repeat(64),
  },
};

function request(mode: "resend" | "reset" = "resend") {
  return new Request("https://tenue.example/api/parent-auth/support", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      origin: "https://tenue.example",
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
    },
    body: JSON.stringify({ parentAccountId, mode }),
  });
}

describe("POST /api/parent-auth/support", () => {
  beforeEach(() => {
    mocks.requireRole.mockReset().mockResolvedValue({ role: "beheerder" });
    mocks.serverRpc.mockReset().mockResolvedValue({ data: preparation, error: null });
    mocks.adminRpc.mockReset().mockResolvedValue({
      data: "ouder@example.nl",
      error: null,
    });
    mocks.deliver.mockReset().mockResolvedValue({ outcome: "provider_accepted" });
  });

  it("staat uitsluitend beheerders toe", async () => {
    mocks.requireRole.mockRejectedValueOnce(
      new Error("STAFF_AUTHORIZATION_REQUIRED"),
    );

    const response = await POST(request());

    expect(response.status).toBe(403);
    expect(mocks.requireRole).toHaveBeenCalledWith(["beheerder"]);
    expect(mocks.serverRpc).not.toHaveBeenCalled();
    expect(mocks.adminRpc).not.toHaveBeenCalled();
    expect(mocks.deliver).not.toHaveBeenCalled();
  });

  it("bereidt reset server-side voor en resolveert het adres alleen via de admin-client", async () => {
    const response = await POST(request("reset"));

    expect(response.status).toBe(200);
    expect(mocks.serverRpc).toHaveBeenCalledWith(
      "prepare_parent_otp_support_delivery_v1",
      {
        p_parent_account_id: parentAccountId,
        p_mode: "reset",
        p_challenge_id: challengeId,
        p_code_hash: "c".repeat(64),
      },
    );
    expect(mocks.adminRpc).toHaveBeenCalledWith(
      "resolve_parent_otp_delivery_recipient_v1",
      { p_delivery_attempt_id: deliveryAttemptId },
    );
    expect(mocks.deliver).toHaveBeenCalledWith(
      expect.anything(),
      preparation,
      "ouder@example.nl",
      "https://tenue.example",
    );
  });

  it("retourneert alleen het veilige resultaat, nooit adres, code, link of provider-ID", async () => {
    const response = await POST(request());
    const text = await response.text();

    expect(response.status).toBe(200);
    expect(JSON.parse(text)).toEqual({
      outcome: "provider_accepted",
      reused: true,
      expiresAt,
    });
    expect(response.headers.get("cache-control")).toBe(
      "private, no-store, max-age=0",
    );
    expect(text).not.toContain("ouder@example.nl");
    expect(text).not.toContain("123456");
    expect(text).not.toContain("v1.");
    expect(text).not.toContain("providerMessageId");
  });
});
