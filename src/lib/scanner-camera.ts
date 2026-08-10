export type BarcodeDetectorLike = {
  detect(source: HTMLVideoElement): Promise<Array<{ rawValue: string }>>;
};

export type BarcodeDetectorConstructor = {
  new(options: { formats: string[] }): BarcodeDetectorLike;
  getSupportedFormats?: () => Promise<string[]>;
};

export async function supportsNativeQrDetection(
  Detector: BarcodeDetectorConstructor | undefined,
) {
  if (!Detector) return false;
  if (typeof Detector.getSupportedFormats !== "function") return true;
  try {
    return (await Detector.getSupportedFormats()).includes("qr_code");
  } catch {
    return false;
  }
}
