import { describe, expect, it } from "vitest";
import { extractQrLocator } from "@/lib/qr-payload";

const locator = `q2.k1.${"a".repeat(43)}`;

describe("QR locator extraction", () => {
  it("accepts a bare opaque locator", () => {
    expect(extractQrLocator(locator)).toBe(locator);
  });

  it("extracts a locator from a HTTPS fragment without transmitting it", () => {
    expect(
      extractQrLocator(`https://tenue.duindorpsv.nl/qr#${locator}`),
    ).toBe(locator);
  });

  it.each([
    `https://tenue.duindorpsv.nl/qr?token=${locator}`,
    `https://tenue.duindorpsv.nl/qr?source=scanner#${locator}`,
    `http://tenue.duindorpsv.nl/qr#${locator}`,
    `https://user:pass@tenue.duindorpsv.nl/qr#${locator}`,
    `https://tenue.duindorpsv.nl/uitgifte#${locator}`,
    `v1.${"a".repeat(43)}`,
    "https://example.nl/lid/123",
  ])("rejects legacy or non-canonical payload %s", (value) => {
    expect(extractQrLocator(value)).toBeNull();
  });
});
