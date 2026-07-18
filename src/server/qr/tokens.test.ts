import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { deriveQrBearerToken, fulfilmentCommitRequestSchema, fulfilmentLookupRequestSchema, hashQrBearerToken } from "@/server/qr/tokens";

const orderId = "00000000-0000-4000-8000-000000000001";
const originalPepper = process.env.PARENT_TOKEN_PEPPER;

describe("QR bearer token boundary", () => {
  beforeEach(() => { process.env.PARENT_TOKEN_PEPPER = "test-pepper-with-at-least-thirty-two-characters"; });
  afterEach(() => {
    if (originalPepper === undefined) delete process.env.PARENT_TOKEN_PEPPER;
    else process.env.PARENT_TOKEN_PEPPER = originalPepper;
  });

  it("derives one opaque 256-bit token per order and version", () => {
    const first = deriveQrBearerToken(orderId, 1);
    expect(first).toBe(deriveQrBearerToken(orderId, 1));
    expect(first).not.toBe(deriveQrBearerToken(orderId, 2));
    expect(first).not.toContain(orderId);
    expect(hashQrBearerToken(first)).toMatch(/^[a-f0-9]{64}$/);
  });

  it("rejects arbitrary lookup strings", () => {
    expect(fulfilmentLookupRequestSchema.safeParse({ token: "lid@example.nl" }).success).toBe(false);
  });

  it("rejects duplicate lines during fulfilment", () => {
    const token = deriveQrBearerToken(orderId);
    const result = fulfilmentCommitRequestSchema.safeParse({ orderId, orderLineIds: [orderId, orderId], location: "Clubhuis", token });
    expect(result.success).toBe(false);
  });
});
