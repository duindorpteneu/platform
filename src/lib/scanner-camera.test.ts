import { describe, expect, it, vi } from "vitest";
import {
  supportsNativeQrDetection,
  type BarcodeDetectorConstructor,
} from "./scanner-camera";

function detector(
  getSupportedFormats?: () => Promise<string[]>,
): BarcodeDetectorConstructor {
  class Detector {
    static getSupportedFormats = getSupportedFormats;
    async detect() {
      return [];
    }
  }
  return Detector;
}

describe("scanner camera backend", () => {
  it("kiest alleen native wanneer QR aantoonbaar wordt ondersteund", async () => {
    expect(await supportsNativeQrDetection(undefined)).toBe(false);
    expect(await supportsNativeQrDetection(detector(
      vi.fn().mockResolvedValue(["aztec", "qr_code"]),
    ))).toBe(true);
    expect(await supportsNativeQrDetection(detector(
      vi.fn().mockResolvedValue(["aztec"]),
    ))).toBe(false);
  });

  it("ondersteunt legacy detectors en valt bij een formatfout veilig terug", async () => {
    expect(await supportsNativeQrDetection(detector())).toBe(true);
    expect(await supportsNativeQrDetection(detector(
      vi.fn().mockRejectedValue(new Error("Detector niet beschikbaar")),
    ))).toBe(false);
  });
});
