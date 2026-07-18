const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export const CORRELATION_ID_HEADER = "x-correlation-id";

export function normalizeCorrelationId(value: string | null | undefined) {
  const candidate = value?.trim();
  return candidate && UUID_PATTERN.test(candidate) ? candidate.toLowerCase() : null;
}

export function resolveCorrelationId(value: string | null | undefined) {
  return normalizeCorrelationId(value) ?? crypto.randomUUID();
}

export function withCorrelationId(headers: Headers, correlationId: string) {
  const nextHeaders = new Headers(headers);
  nextHeaders.set(CORRELATION_ID_HEADER, correlationId);
  return nextHeaders;
}
