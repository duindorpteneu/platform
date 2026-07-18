import { describe, expect, it } from "vitest";
import { extractQrBearerToken } from "@/lib/qr-payload";

const token = `v1.${"a".repeat(43)}`;

describe("QR payload extraction", () => {
  it("accepts a bare bearer token", () => {
    expect(extractQrBearerToken(token)).toBe(token);
  });

  it("extracts the token from the canonical HTTPS query", () => {
    expect(extractQrBearerToken(`https://tenue.duindorpsv.nl/qr?token=${token}`)).toBe(token);
  });

  it("rejects URLs and values without a canonical token", () => {
    expect(extractQrBearerToken("https://example.nl/lid/123")).toBeNull();
  });
});
