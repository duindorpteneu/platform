import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  buildQrFragmentUrl,
  deriveQrLocator,
  deriveQrScanGrant,
  fulfilmentCommitRequestSchema,
  fulfilmentExchangeRequestSchema,
  generateQrDerivationNonce,
  hashQrLocator,
  hashQrScanGrant,
  qrAcceptedKeyMetadata,
  qrKeyVersion,
  qrPepperFingerprint,
} from "@/server/qr/tokens";

const orderId = "00000000-0000-4000-8000-000000000001";
const requestId = "00000000-0000-4000-8000-000000000002";
const actorId = "00000000-0000-4000-8000-000000000003";
const nonce = Buffer.alloc(32, 3).toString("base64url");
const currentPepper = Buffer.alloc(32, 7).toString("base64url");
const previousPepper = Buffer.alloc(32, 6).toString("base64url");
const original = {
  pepper: process.env.QR_TOKEN_PEPPER,
  version: process.env.QR_TOKEN_PEPPER_VERSION,
  previousPepper: process.env.QR_TOKEN_PREVIOUS_PEPPER,
  previousVersion: process.env.QR_TOKEN_PREVIOUS_PEPPER_VERSION,
  parentPepper: process.env.PARENT_TOKEN_PEPPER,
};

function locator(input: Partial<{
  generation: number;
  keyVersion: number;
  nonce: string;
}> = {}) {
  return deriveQrLocator({
    generation: input.generation ?? 1,
    keyVersion: input.keyVersion ?? 7,
    nonce: input.nonce ?? nonce,
    orderId,
  });
}

describe("QR locator and scan-grant boundary", () => {
  beforeEach(() => {
    process.env.QR_TOKEN_PEPPER = currentPepper;
    process.env.QR_TOKEN_PEPPER_VERSION = "7";
    process.env.QR_TOKEN_PREVIOUS_PEPPER = previousPepper;
    process.env.QR_TOKEN_PREVIOUS_PEPPER_VERSION = "6";
    process.env.PARENT_TOKEN_PEPPER =
      "unrelated-parent-pepper-with-thirty-two-characters";
  });

  afterEach(() => {
    for (const [name, value] of [
      ["QR_TOKEN_PEPPER", original.pepper],
      ["QR_TOKEN_PEPPER_VERSION", original.version],
      ["QR_TOKEN_PREVIOUS_PEPPER", original.previousPepper],
      ["QR_TOKEN_PREVIOUS_PEPPER_VERSION", original.previousVersion],
      ["PARENT_TOKEN_PEPPER", original.parentPepper],
    ] as const) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  });

  it("derives a random-nonce-bound opaque locator", () => {
    const first = locator();
    expect(first).toBe(locator());
    expect(first).not.toBe(locator({ generation: 2 }));
    expect(first).not.toBe(locator({
      nonce: Buffer.alloc(32, 4).toString("base64url"),
    }));
    expect(first).not.toContain(orderId);
    expect(first).not.toContain(nonce);
    expect(first).toMatch(/^q2\.k7\.[A-Za-z0-9_-]{43}$/);
    expect(hashQrLocator(first)).toMatch(/^[a-f0-9]{64}$/);
    expect(qrPepperFingerprint()).toMatch(/^[a-f0-9]{64}$/);
    expect(qrKeyVersion()).toBe(7);
    expect(generateQrDerivationNonce()).toMatch(/^[A-Za-z0-9_-]{43}$/);

    process.env.PARENT_TOKEN_PEPPER =
      "another-unrelated-parent-pepper-which-is-long-enough";
    expect(locator()).toBe(first);
  });

  it("accepts the previous key only during an explicit rotation window", () => {
    const oldLocator = locator({ keyVersion: 6 });
    expect(oldLocator).toMatch(/^q2\.k6\./);
    expect(hashQrLocator(oldLocator)).toMatch(/^[a-f0-9]{64}$/);
    expect(qrAcceptedKeyMetadata()).toMatchObject({
      current: { version: 7 },
      previous: { version: 6 },
    });

    delete process.env.QR_TOKEN_PREVIOUS_PEPPER;
    delete process.env.QR_TOKEN_PREVIOUS_PEPPER_VERSION;
    expect(() => hashQrLocator(oldLocator)).toThrow(
      "QR_TOKEN_KEY_VERSION_UNAVAILABLE",
    );
  });

  it("derives a versioned session- and request-bound scan grant", () => {
    const qrLocator = locator();
    const grant = deriveQrScanGrant({
      actorId,
      locator: qrLocator,
      requestId,
      staffSessionHash: "b".repeat(64),
    });
    expect(grant).toMatch(/^sg2\.k7\.[A-Za-z0-9_-]{43}$/);
    expect(hashQrScanGrant(grant)).toMatch(/^[a-f0-9]{64}$/);
    expect(deriveQrScanGrant({
      actorId,
      locator: qrLocator,
      requestId,
      staffSessionHash: "c".repeat(64),
    })).not.toBe(grant);
  });

  it("puts an optional canonical locator URL only in a fragment", () => {
    const qrLocator = locator();
    const url = new URL(buildQrFragmentUrl(
      "https://tenue.duindorpsv.nl",
      qrLocator,
    ));
    expect(url.pathname).toBe("/qr");
    expect(url.search).toBe("");
    expect(url.hash).toBe(`#${qrLocator}`);
  });

  it("requires a dedicated current QR key", () => {
    delete process.env.QR_TOKEN_PEPPER;
    expect(() => locator()).toThrow("QR_TOKEN_KEY_VERSION_UNAVAILABLE");
  });

  it("rejects arbitrary exchange locators and extra input", () => {
    expect(fulfilmentExchangeRequestSchema.safeParse({
      locator: "lid@example.nl",
      requestId,
    }).success).toBe(false);
    expect(fulfilmentExchangeRequestSchema.safeParse({
      locator: locator(),
      requestId,
      orderId,
    }).success).toBe(false);
  });

  it("rejects duplicate lines and client-controlled order/location", () => {
    const scanGrant = deriveQrScanGrant({
      actorId,
      locator: locator(),
      requestId,
      staffSessionHash: "b".repeat(64),
    });
    expect(fulfilmentCommitRequestSchema.safeParse({
      scanGrant,
      requestId,
      orderLineIds: [orderId, orderId],
    }).success).toBe(false);
    expect(fulfilmentCommitRequestSchema.safeParse({
      scanGrant,
      requestId,
      orderLineIds: [orderId],
      orderId,
      location: "Clientgestuurd",
    }).success).toBe(false);
  });
});
