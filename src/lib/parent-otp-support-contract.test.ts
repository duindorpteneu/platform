import { describe, expect, it } from "vitest";
import {
  parentOtpSupportActionResponseSchema,
  parentOtpSupportSchema,
} from "@/lib/parent-otp-support-contract";

describe("parent OTP-supportcontract", () => {
  it("accepteert uitsluitend gemaskeerde operationele metadata", () => {
    const result = parentOtpSupportSchema.parse({
      parentAccountId: "11111111-1111-4111-8111-111111111111",
      status: "active",
      loginEmailMasked: "o****@example.nl",
      lastCodeRequestedAt: null,
      lastDeliveryAttemptAt: null,
      lastDeliveryStatus: null,
      codeExpiresAt: null,
      lastSuccessfulLoginAt: null,
      linkedChildren: [{
        memberId: "22222222-2222-4222-8222-222222222222",
        memberSeasonId: "33333333-3333-4333-8333-333333333333",
        memberName: "Voorbeeld Lid",
        team: "JO11-1",
      }],
    });
    expect(result.loginEmailMasked).toContain("*");
    expect(result).not.toHaveProperty("email");
    expect(result).not.toHaveProperty("code");
    expect(result).not.toHaveProperty("credential");
  });

  it("weigert credentials en provider-ID's in de actieresponse", () => {
    const safe = {
      outcome: "provider_accepted",
      reused: true,
      expiresAt: "2026-08-21T15:30:00.000Z",
    };
    expect(parentOtpSupportActionResponseSchema.safeParse(safe).success)
      .toBe(true);
    expect(parentOtpSupportActionResponseSchema.safeParse({
      ...safe,
      code: "123456",
    }).success).toBe(false);
    expect(parentOtpSupportActionResponseSchema.safeParse({
      ...safe,
      providerMessageId: "secret-provider-id",
    }).success).toBe(false);
  });
});
