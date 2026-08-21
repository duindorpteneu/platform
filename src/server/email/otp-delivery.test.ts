import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { PreparedParentOtpV3 } from "@/lib/mail-v2-contract";

const mocks = vi.hoisted(() => ({
  authorize: vi.fn(),
  complete: vi.fn(),
  render: vi.fn(),
  send: vi.fn(),
}));

vi.mock("@/server/auth/parent", () => ({
  deriveParentCode: () => "123456",
  deriveParentDirectCredential: () =>
    `v1.11111111-1111-4111-8111-111111111111.${"A".repeat(43)}`,
}));
vi.mock("@/server/email/otp", () => ({
  authorizeParentOtpV2: mocks.authorize,
  completeParentOtpV2: mocks.complete,
  renderParentOtpV3: mocks.render,
}));
vi.mock("@/server/email/provider", () => ({
  sendParentOtpV2Email: mocks.send,
}));

import { deliverPreparedParentOtpV3 } from "./otp-delivery";

const preparation = {
  status: "prepared",
  challengeId: "11111111-1111-4111-8111-111111111111",
  deliveryAttemptId: "22222222-2222-4222-8222-222222222222",
} as PreparedParentOtpV3;

describe("deliverPreparedParentOtpV3", () => {
  beforeEach(() => {
    process.env.EMAIL_PROVIDER = "smtp";
    mocks.authorize.mockReset().mockResolvedValue(true);
    mocks.complete.mockReset().mockResolvedValue({ status: "completed" });
    mocks.render.mockReset().mockReturnValue({
      subject: "Uw verificatiecode",
      text: "Vluchtige tekst",
      html: "<p>Vluchtige tekst</p>",
      fromName: "Duindorp SV",
      fromEmail: "kleding@duindorpsv.nl",
      replyToEmail: "kleding@duindorpsv.nl",
    });
    mocks.send.mockReset();
  });

  afterEach(() => {
    delete process.env.EMAIL_PROVIDER;
  });

  it("legt een permanente SMTP-ontvangerfout als providerbewijs vast", async () => {
    mocks.send.mockResolvedValue({
      delivered: false,
      reason: "provider_rejected",
      outcome: "failed",
      deliveryState: "permanent_rejection",
      providerCode: "550",
      enhancedStatusCode: "5.1.1",
      recipientFailure: true,
    });
    const appClient = { rpc: vi.fn() };
    const admin = { schema: () => appClient };

    await expect(deliverPreparedParentOtpV3(
      admin as never,
      preparation,
      "ouder@example.nl",
      "https://tenue.example",
    )).resolves.toEqual({ outcome: "provider_rejected" });

    expect(mocks.complete).toHaveBeenCalledWith(
      appClient,
      preparation.deliveryAttemptId,
      {
        outcome: "provider_rejected",
        errorCode: "provider_rejected",
      },
      {
        provider: "smtp",
        providerState: "permanent_rejection",
        responseCode: "550",
        enhancedStatusCode: "5.1.1",
        recipientFailure: true,
      },
    );
    expect(JSON.stringify(mocks.complete.mock.calls)).not.toContain(
      "ouder@example.nl",
    );
  });

  it("bewaart een bekende pre-send blokkade bij databaseacknowledgementfouten", async () => {
    mocks.authorize.mockResolvedValue(false);
    mocks.complete.mockRejectedValue(new Error("completion unavailable"));
    const appClient = { rpc: vi.fn() };
    const admin = { schema: () => appClient };

    await expect(deliverPreparedParentOtpV3(
      admin as never,
      preparation,
      "ouder@example.nl",
      "https://tenue.example",
    )).resolves.toEqual({ outcome: "disabled" });

    expect(mocks.send).not.toHaveBeenCalled();
    expect(mocks.complete).toHaveBeenCalledTimes(2);
    expect(mocks.complete.mock.calls[0]).toEqual([
      appClient,
      preparation.deliveryAttemptId,
      {
        outcome: "disabled",
        errorCode: "send_authorization_denied",
      },
      {
        provider: "smtp",
        providerState: "disabled",
        recipientFailure: false,
      },
    ]);
    expect(mocks.complete.mock.calls[1]).toEqual(mocks.complete.mock.calls[0]);
  });

  it("sluit een exceptionpad expliciet als delivery uncertain", async () => {
    mocks.send.mockRejectedValue(new Error("provider transport failed"));
    const appClient = { rpc: vi.fn() };
    const admin = { schema: () => appClient };

    await expect(deliverPreparedParentOtpV3(
      admin as never,
      preparation,
      "ouder@example.nl",
      "https://tenue.example",
    )).resolves.toEqual({ outcome: "delivery_uncertain" });

    expect(mocks.complete).toHaveBeenCalledTimes(1);
    expect(mocks.complete).toHaveBeenCalledWith(
      appClient,
      preparation.deliveryAttemptId,
      {
        outcome: "delivery_uncertain",
        errorCode: "delivery_completion_uncertain",
      },
    );
    expect(JSON.stringify(mocks.complete.mock.calls)).not.toContain(
      "ouder@example.nl",
    );
  });

  it("bewaart het bekende providerresultaat bij een onzekere databaseacknowledgement", async () => {
    mocks.send.mockResolvedValue({
      delivered: true,
      providerMessageId: "smtp-accepted-1",
    });
    mocks.complete
      .mockRejectedValueOnce(new Error("provider evidence acknowledgement failed"))
      .mockResolvedValueOnce({ status: "completed" });
    const appClient = { rpc: vi.fn() };
    const admin = { schema: () => appClient };

    await expect(deliverPreparedParentOtpV3(
      admin as never,
      preparation,
      "ouder@example.nl",
      "https://tenue.example",
    )).resolves.toEqual({ outcome: "provider_accepted" });

    expect(mocks.complete).toHaveBeenCalledTimes(2);
    expect(mocks.complete.mock.calls[0]).toEqual([
      appClient,
      preparation.deliveryAttemptId,
      {
        outcome: "accepted",
        providerMessageId: "smtp-accepted-1",
      },
      {
        provider: "smtp",
        providerState: "provider_accepted",
        responseCode: undefined,
        enhancedStatusCode: undefined,
        recipientFailure: false,
      },
    ]);
    expect(mocks.complete.mock.calls[1]).toEqual(mocks.complete.mock.calls[0]);
  });
});
