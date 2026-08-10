import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  requireRole: vi.fn(),
  rpc: vi.fn(),
  send: vi.fn(),
}));

vi.mock("@/server/auth/staff", () => ({
  requireStaffRole: mocks.requireRole,
}));
vi.mock("@/server/supabase/server", () => ({
  getSupabaseServerClient: vi.fn(async () => ({
    schema: () => ({ rpc: mocks.rpc }),
  })),
}));
vi.mock("@/server/email/sendgrid", () => ({
  sendMailV2TestEmail: mocks.send,
}));

import { sendMailV2TestDelivery } from "@/server/email/mail-v2-test-delivery";

const originalEnv = { ...process.env };
const requestId = "a3310000-0000-4000-8000-000000000001";
const deliveryId = "a3310000-0000-4000-8000-000000000002";
const contentHash = "a".repeat(64);
const preparation = {
  deliveryId,
  status: "prepared",
  reused: false,
  template: {
    id: "a3310000-0000-4000-8000-000000000003",
    contentHash,
    source: {
      templateKey: "package_complete",
      subjectSource: "Pakket compleet voor {{member_first_name}}",
      preheaderSource: "Alle pakketregels zijn afgehaald.",
      bodyTipTap: {
        type: "doc",
        content: [{
          type: "protectedBlock",
          attrs: { kind: "full_package" },
        }],
      },
      allowedShortcodes: ["member_first_name"],
      allowedProtectedNodes: ["full_package"],
      requiredProtectedNodes: ["full_package"],
    },
  },
  branding: {
    id: "a3310000-0000-4000-8000-000000000004",
    contentHash: "b".repeat(64),
    values: {
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
    },
  },
};

describe("mail-v2 testdeliveryservice", () => {
  beforeEach(() => {
    process.env.SENDGRID_SMOKE_RECIPIENT = "testinbox@example.invalid";
    mocks.requireRole.mockReset().mockResolvedValue({
      userId: "a3310000-0000-4000-8000-000000000005",
      role: "beheerder",
    });
    mocks.rpc.mockReset().mockImplementation(async (name: string) => {
      if (name === "prepare_mail_test_delivery_v1") {
        return { data: preparation, error: null };
      }
      return {
        data: {
          deliveryId,
          status: "accepted",
          reused: false,
        },
        error: null,
      };
    });
    mocks.send.mockReset().mockResolvedValue({
      delivered: true,
      providerMessageId: "provider-message-not-persisted",
    });
  });

  afterEach(() => {
    process.env = { ...originalEnv };
  });

  it("rendert met fictieve data en gebruikt uitsluitend de vaste omgevingsinbox", async () => {
    const result = await sendMailV2TestDelivery(
      {
        requestId,
        templateKey: "package_complete",
        expectedContentHash: contentHash,
      },
      "a3310000-0000-4000-8000-000000000006",
      "https://tenue.duindorpsv.nl",
    );

    expect(mocks.requireRole).toHaveBeenCalledWith(["beheerder"]);
    expect(mocks.send).toHaveBeenCalledWith(expect.objectContaining({
      testDeliveryId: deliveryId,
      subject: "Pakket compleet voor Sophie",
      fromEmail: "kleding@duindorpsv.nl",
    }));
    expect(mocks.send.mock.calls[0][0]).not.toHaveProperty("recipientEmail");
    expect(JSON.stringify(mocks.send.mock.calls[0][0]))
      .not.toContain("provider-message-not-persisted");
    expect(mocks.rpc).toHaveBeenNthCalledWith(
      2,
      "finalize_mail_test_delivery_v2",
      expect.objectContaining({
        p_delivery_id: deliveryId,
        p_outcome: "accepted",
        p_provider_http_message_id:
          "provider-message-not-persisted",
      }),
    );
    expect(result.data).toMatchObject({ status: "accepted", reused: false });
  });

  it("verstuurt een hergebruikte voorbereiding nooit opnieuw", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: {
        deliveryId,
        status: "prepared",
        reused: true,
      },
      error: null,
    });

    const result = await sendMailV2TestDelivery(
      {
        requestId,
        templateKey: "package_complete",
        expectedContentHash: contentHash,
      },
      null,
      "https://tenue.duindorpsv.nl",
    );

    expect(result.data).toEqual({
      deliveryId,
      status: "prepared",
      reused: true,
    });
    expect(mocks.send).not.toHaveBeenCalled();
    expect(mocks.rpc).toHaveBeenCalledTimes(1);
  });

  it("finaliseert een onzekere provideruitkomst zonder retry", async () => {
    mocks.send.mockResolvedValueOnce({
      delivered: false,
      reason: "delivery_uncertain",
      outcome: "delivery_uncertain",
    });
    mocks.rpc.mockImplementation(async (name: string) => (
      name === "prepare_mail_test_delivery_v1"
        ? { data: preparation, error: null }
        : {
          data: {
            deliveryId,
            status: "delivery_uncertain",
            reused: false,
          },
          error: null,
        }
    ));

    const result = await sendMailV2TestDelivery(
      {
        requestId,
        templateKey: "package_complete",
        expectedContentHash: contentHash,
      },
      null,
      "https://tenue.duindorpsv.nl",
    );

    expect(mocks.send).toHaveBeenCalledTimes(1);
    expect(mocks.rpc).toHaveBeenNthCalledWith(
      2,
      "finalize_mail_test_delivery_v2",
      expect.objectContaining({ p_outcome: "delivery_uncertain" }),
    );
    expect(result.data).toMatchObject({ status: "delivery_uncertain" });
  });

  it("controleert beheerbevoegdheid vóór het bestaan van de testinbox", async () => {
    delete process.env.SENDGRID_SMOKE_RECIPIENT;
    mocks.requireRole.mockRejectedValueOnce(
      new Error("STAFF_AUTHORIZATION_REQUIRED"),
    );

    await expect(sendMailV2TestDelivery(
      {
        requestId,
        templateKey: "package_complete",
        expectedContentHash: contentHash,
      },
      null,
      "https://tenue.duindorpsv.nl",
    )).rejects.toThrow("STAFF_AUTHORIZATION_REQUIRED");
    expect(mocks.rpc).not.toHaveBeenCalled();
    expect(mocks.send).not.toHaveBeenCalled();
  });

  it("blokkeert zonder vaste testinbox vóór databasevoorbereiding", async () => {
    delete process.env.SENDGRID_SMOKE_RECIPIENT;

    await expect(sendMailV2TestDelivery(
      {
        requestId,
        templateKey: "package_complete",
        expectedContentHash: contentHash,
      },
      null,
      "https://tenue.duindorpsv.nl",
    )).rejects.toThrow("MAIL_V2_TEST_RECIPIENT_UNAVAILABLE");
    expect(mocks.rpc).not.toHaveBeenCalled();
    expect(mocks.send).not.toHaveBeenCalled();
  });
});
