import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  requireStaffRole: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock("@/server/auth/staff", () => ({
  requireStaffRole: mocks.requireStaffRole,
}));
vi.mock("@/server/supabase/server", () => ({
  getSupabaseServerClient: vi.fn(async () => ({
    schema: () => ({ rpc: mocks.rpc }),
  })),
}));
vi.mock("@/lib/env", () => ({
  getServerEnv: () => ({ APP_BASE_URL: "https://tenue.example" }),
}));

import { previewMailV2Campaign } from "@/server/email/mail-v2-campaigns";

const preflightId = "74100000-0000-4000-8000-000000000001";
const memberSeasonId = "74100000-0000-4000-8000-000000000002";
const orderId = "74100000-0000-4000-8000-000000000003";
const requestId = "74100000-0000-4000-8000-000000000004";
const revision = "a".repeat(64);

const branding = {
  id: "74100000-0000-4000-8000-000000000010",
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
  primaryColor: "#17418B",
  secondaryColor: "#0B2E63",
  accentColor: "#2E69CC",
  footerText: "Kledingcommissie Duindorp SV",
  contrastValidated: true,
  contentHash: "b".repeat(64),
};

function rpcPreflight(eligibilityRevision = revision) {
  return {
    preflightId,
    templateKey: "payment_request",
    seasonId: "74100000-0000-4000-8000-000000000005",
    eligibilityRevision: revision,
    selectedTargetCount: 1,
    eligibleTargetCount: 1,
    eligibleEventCount: 1,
    skippedTargetCount: 0,
    blockedTargetCount: 0,
    parentGroupCount: 1,
    expiresAt: "2026-08-03T18:00:00.000Z",
    reused: false,
    previewGroup: {
      groupId: preflightId,
      eligibilityRevision,
      templateKey: "payment_request",
      template: {
        id: "74100000-0000-4000-8000-000000000011",
        templateKey: "payment_request",
        subjectSource: "Betaalverzoek voor {{member_first_name}}",
        preheaderSource: "Betaal het vaste pakketbedrag.",
        bodyTipTap: {
          type: "doc",
          content: [
            {
              type: "paragraph",
              content: [{
                type: "text",
                text: "Controleer het pakketbedrag.",
              }],
            },
            { type: "protectedBlock", attrs: { kind: "payment_summary" } },
            { type: "protectedBlock", attrs: { kind: "payment_action" } },
          ],
        },
        allowedShortcodes: [
          "club_name",
          "member_first_name",
          "package_amount",
          "payment_url",
          "portal_url",
          "contact_email",
          "privacy_url",
        ],
        allowedProtectedNodes: ["payment_summary", "payment_action"],
        requiredProtectedNodes: ["payment_summary", "payment_action"],
        contentHash: "c".repeat(64),
      },
      branding,
      events: [{
        eventId: "74100000-0000-4000-8000-000000000012",
        payload: {
          memberSeasonId,
          memberFirstName: "<Sophie>",
          memberFullName: "<Sophie> Campagne",
          teamName: "JO11-1",
          seasonName: "2026/2027",
          orderId,
          packageName: "Speler",
          amountCents: 12_500,
          currency: "EUR",
          lines: [],
        },
      }],
    },
  };
}

describe("mail-v2 campagnepreflightservice", () => {
  beforeEach(() => {
    mocks.requireStaffRole.mockReset().mockResolvedValue({
      role: "beheerder",
    });
    mocks.rpc.mockReset().mockResolvedValue({
      data: rpcPreflight(),
      error: null,
    });
  });

  it("rendert exact server-side en verwijdert de ruwe previewgroep", async () => {
    const result = await previewMailV2Campaign({
      templateKey: "payment_request",
      targetIds: [orderId],
      requestId,
    });

    expect(result.error).toBeNull();
    expect(result.data?.preview?.subject).toContain("<Sophie>");
    expect(result.data?.preview?.html).toContain("&lt;Sophie&gt;");
    expect(result.data?.preview?.text).toContain("€ 125,00");
    expect(JSON.stringify(result.data)).not.toContain("previewGroup");
    expect(JSON.stringify(result.data)).not.toContain("dateOfBirth");
    expect(mocks.rpc).toHaveBeenCalledWith(
      "preview_mail_v2_campaign_v1",
      {
        p_template_key: "payment_request",
        p_target_ids: [orderId],
        p_request_id: requestId,
      },
    );
  });

  it("weigert een voorbeeldgroep die niet exact bij de preflight hoort", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: rpcPreflight("d".repeat(64)),
      error: null,
    });

    await expect(previewMailV2Campaign({
      templateKey: "payment_request",
      targetIds: [orderId],
      requestId,
    })).rejects.toThrow("MAIL_V2_CAMPAIGN_PREVIEW_RESPONSE_INVALID");
  });
});
