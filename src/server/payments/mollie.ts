import { z } from "zod";
import { BODY_POLICIES, readBoundedText, RequestBodyError, validateBodyHeaders } from "@/server/security/request";

export const mollieStatusSchema = z.enum(["open", "pending", "authorized", "paid", "failed", "canceled", "expired"]);
const mollieRefundStatusSchema = z.enum(["queued", "pending", "canceled", "processing", "failed", "refunded"]);

const amountSchema = z.object({ currency: z.string(), value: z.string() }).strict();
const linkSchema = z.object({ href: z.string().url(), type: z.string().optional() }).passthrough();
const refundSchema = z.object({
  resource: z.literal("refund").optional(),
  id: z.string().regex(/^re_[A-Za-z0-9]+$/),
  status: mollieRefundStatusSchema,
  amount: amountSchema,
}).passthrough();
const refundListSchema = z.object({
  _embedded: z.object({ refunds: z.array(refundSchema).max(250) }).passthrough(),
}).passthrough();

export const molliePaymentSchema = z.object({
  resource: z.literal("payment").optional(),
  id: z.string().regex(/^tr_[A-Za-z0-9]+$/),
  status: mollieStatusSchema,
  mode: z.enum(["test", "live"]).optional(),
  amount: amountSchema,
  amountRefunded: amountSchema.optional(),
  amountRemaining: amountSchema.optional(),
  metadata: z.union([z.record(z.unknown()), z.string(), z.null()]),
  createdAt: z.string().datetime({ offset: true }).nullable().optional(),
  expiresAt: z.string().datetime({ offset: true }).nullable().optional(),
  paidAt: z.string().datetime({ offset: true }).nullable().optional(),
  canceledAt: z.string().datetime({ offset: true }).nullable().optional(),
  failedAt: z.string().datetime({ offset: true }).nullable().optional(),
  _links: z.object({ checkout: linkSchema.optional() }).passthrough(),
  _embedded: z.object({ refunds: z.array(refundSchema).max(250).optional() }).passthrough().optional(),
}).passthrough();

export const mollieMetadataSchema = z.object({
  payment_id: z.string().uuid(),
  order_id: z.string().uuid(),
  member_id: z.string().uuid(),
  season_id: z.string().uuid(),
  schema_version: z.literal(1),
}).strict();

export type MolliePayment = z.infer<typeof molliePaymentSchema>;
export type MollieMetadata = z.infer<typeof mollieMetadataSchema>;

export class MollieRequestError extends Error {
  constructor(public readonly status: number, public readonly retryable: boolean) {
    super("MOLLIE_REQUEST_FAILED");
  }
}

function parseResponse(payload: unknown) {
  const parsed = molliePaymentSchema.safeParse(payload);
  if (!parsed.success) throw new Error("MOLLIE_RESPONSE_INVALID");
  return parsed.data;
}

async function readMollieResponse(response: Response) {
  try {
    return await readBoundedText(response, { maxBytes: 100_000, timeoutMs: 5_000 });
  } catch (error) {
    if (error instanceof RequestBodyError && error.status === 413) {
      throw new Error("MOLLIE_RESPONSE_TOO_LARGE");
    }
    throw new Error("MOLLIE_RESPONSE_INVALID");
  }
}

async function requestPayment(url: string, init: RequestInit, fetcher: typeof fetch) {
  const response = await fetcher(url, { ...init, signal: init.signal ?? AbortSignal.timeout(10_000) });
  if (!response.ok) throw new MollieRequestError(response.status, response.status === 429 || response.status >= 500);
  const contentLength = Number(response.headers.get("content-length") ?? 0);
  if (contentLength > 100_000) throw new Error("MOLLIE_RESPONSE_TOO_LARGE");
  const raw = await readMollieResponse(response);
  try {
    return parseResponse(JSON.parse(raw));
  } catch (error) {
    if (error instanceof Error && error.message.startsWith("MOLLIE_")) throw error;
    throw new Error("MOLLIE_RESPONSE_INVALID");
  }
}

async function requestRefunds(url: string, init: RequestInit, fetcher: typeof fetch) {
  const response = await fetcher(url, { ...init, signal: init.signal ?? AbortSignal.timeout(10_000) });
  if (!response.ok) throw new MollieRequestError(response.status, response.status === 429 || response.status >= 500);
  const contentLength = Number(response.headers.get("content-length") ?? 0);
  if (contentLength > 100_000) throw new Error("MOLLIE_RESPONSE_TOO_LARGE");
  const raw = await readMollieResponse(response);
  try {
    const parsed = refundListSchema.safeParse(JSON.parse(raw));
    if (!parsed.success) throw new Error("MOLLIE_RESPONSE_INVALID");
    return parsed.data._embedded.refunds;
  } catch (error) {
    if (error instanceof Error && error.message.startsWith("MOLLIE_")) throw error;
    throw new Error("MOLLIE_RESPONSE_INVALID");
  }
}

export function formatMollieAmount(cents: number) {
  if (!Number.isSafeInteger(cents) || cents < 0) throw new Error("INVALID_CENTS");
  return `${Math.floor(cents / 100)}.${String(cents % 100).padStart(2, "0")}`;
}

export function parseMollieAmountCents(amount: { currency: string; value: string }) {
  if (amount.currency !== "EUR" || !/^\d+\.\d{2}$/.test(amount.value)) throw new Error("MOLLIE_AMOUNT_INVALID");
  const [euros, cents] = amount.value.split(".");
  const value = Number(euros) * 100 + Number(cents);
  if (!Number.isSafeInteger(value)) throw new Error("MOLLIE_AMOUNT_INVALID");
  return value;
}

export function parseMollieMetadata(value: unknown) {
  let candidate = value;
  if (typeof value === "string") {
    try { candidate = JSON.parse(value); } catch { throw new Error("MOLLIE_METADATA_INVALID"); }
  }
  const parsed = mollieMetadataSchema.safeParse(candidate);
  if (!parsed.success) throw new Error("MOLLIE_METADATA_INVALID");
  return parsed.data;
}

export function toLocalMollieStatus(payment: MolliePayment) {
  if (payment.amountRefunded && parseMollieAmountCents(payment.amountRefunded) > 0) return "refunded" as const;
  if (payment._embedded?.refunds?.some((refund) => {
    return ["processing", "refunded"].includes(refund.status) && parseMollieAmountCents(refund.amount) > 0;
  })) return "refunded" as const;
  if (payment.status === "authorized") return "pending" as const;
  return payment.status;
}

export function requireHostedCheckoutUrl(payment: MolliePayment) {
  const href = payment._links.checkout?.href;
  if (!href) throw new Error("MOLLIE_CHECKOUT_MISSING");
  const url = new URL(href);
  if (url.protocol !== "https:" || (url.hostname !== "mollie.com" && !url.hostname.endsWith(".mollie.com"))) {
    throw new Error("MOLLIE_CHECKOUT_INVALID");
  }
  return url.toString();
}

export async function createMolliePayment(input: {
  apiKey: string;
  idempotencyKey: string;
  amountCents: number;
  description: string;
  redirectUrl: string;
  webhookUrl: string;
  metadata: MollieMetadata;
}, fetcher: typeof fetch = fetch) {
  const payment = await requestPayment("https://api.mollie.com/v2/payments", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${input.apiKey}`,
      "Content-Type": "application/json",
      "Idempotency-Key": input.idempotencyKey,
    },
    body: JSON.stringify({
      amount: { currency: "EUR", value: formatMollieAmount(input.amountCents) },
      description: input.description.slice(0, 255),
      redirectUrl: input.redirectUrl,
      webhookUrl: input.webhookUrl,
      locale: "nl_NL",
      metadata: input.metadata,
    }),
    cache: "no-store",
  }, fetcher);
  if (parseMollieAmountCents(payment.amount) !== input.amountCents) throw new Error("MOLLIE_AMOUNT_MISMATCH");
  if (JSON.stringify(parseMollieMetadata(payment.metadata)) !== JSON.stringify(input.metadata)) {
    throw new Error("MOLLIE_METADATA_MISMATCH");
  }
  requireHostedCheckoutUrl(payment);
  return payment;
}

export async function getMolliePayment(apiKey: string, providerPaymentId: string, fetcher: typeof fetch = fetch) {
  if (!/^tr_[A-Za-z0-9]+$/.test(providerPaymentId)) throw new Error("MOLLIE_PAYMENT_ID_INVALID");
  const encodedPaymentId = encodeURIComponent(providerPaymentId);
  const request = {
    method: "GET",
    headers: { Authorization: `Bearer ${apiKey}` },
    cache: "no-store",
  } satisfies RequestInit;
  const [payment, refunds] = await Promise.all([
    requestPayment(`https://api.mollie.com/v2/payments/${encodedPaymentId}`, request, fetcher),
    requestRefunds(`https://api.mollie.com/v2/payments/${encodedPaymentId}/refunds?limit=250`, request, fetcher),
  ]);
  return { ...payment, _embedded: { ...payment._embedded, refunds } };
}

export async function extractMollieWebhookPaymentId(request: Request) {
  const headers = validateBodyHeaders(request, BODY_POLICIES.mollieWebhook);
  if (!headers.ok) {
    if (headers.status === 413) throw new RequestBodyError("body_too_large", 413);
    throw new Error("MOLLIE_WEBHOOK_CONTENT_TYPE_INVALID");
  }
  const raw = await readBoundedText(request, BODY_POLICIES.mollieWebhook);
  const parameters = new URLSearchParams(raw);
  const values = parameters.getAll("id");
  if (values.length !== 1 || [...parameters.keys()].some((key) => key !== "id")) {
    throw new Error("MOLLIE_WEBHOOK_INVALID");
  }
  const value = values[0];
  if (typeof value !== "string" || !/^tr_[A-Za-z0-9]+$/.test(value)) throw new Error("MOLLIE_WEBHOOK_INVALID");
  return value;
}
