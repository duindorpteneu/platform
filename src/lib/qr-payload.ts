export const QR_LOCATOR_PATTERN = /^q2\.k[1-9]\d{0,3}\.[A-Za-z0-9_-]{43}$/;
export const QR_SCAN_GRANT_PATTERN =
  /^sg2\.k[1-9]\d{0,3}\.[A-Za-z0-9_-]{43}$/;

export function extractQrLocator(input: string) {
  const value = input.trim();
  if (QR_LOCATOR_PATTERN.test(value)) return value;

  try {
    const url = new URL(value);
    const locator = url.hash.startsWith("#") ? url.hash.slice(1) : "";
    if (
      url.protocol === "https:"
      && !url.username
      && !url.password
      && url.pathname === "/qr"
      && url.search === ""
      && QR_LOCATOR_PATTERN.test(locator)
    ) {
      return locator;
    }
  } catch {
    // Scanners may return either the locator or its canonical fragment URL.
  }
  return null;
}
