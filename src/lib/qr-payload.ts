export const QR_TOKEN_PATTERN = /^v[1-9]\d*\.[A-Za-z0-9_-]{43}$/;

export function extractQrBearerToken(input: string) {
  const value = input.trim();
  if (QR_TOKEN_PATTERN.test(value)) return value;

  try {
    const url = new URL(value);
    const queryToken = url.searchParams.get("token");
    if (queryToken && QR_TOKEN_PATTERN.test(queryToken)) return queryToken;
  } catch {
    // A scanner may provide either a token or an HTTPS URL.
  }

  return null;
}
