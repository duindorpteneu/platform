import { describe, expect, it, vi } from "vitest";
import { createMolliePayment, createMollieRefund, extractMollieWebhookPaymentId, formatMollieAmount, getMolliePayment, molliePaymentSchema, parseMollieAmountCents, parseMollieMetadata, requireHostedCheckoutUrl, toLocalMollieStatus } from "@/server/payments/mollie";

const metadata = { payment_id: "10000000-0000-4000-8000-000000000001", order_id: "10000000-0000-4000-8000-000000000002", member_id: "10000000-0000-4000-8000-000000000003", member_season_id: "10000000-0000-4000-8000-000000000005", season_id: "10000000-0000-4000-8000-000000000004", schema_version: 2 as const };

describe("Mollie provider boundary", () => {
  it("formats and parses exact EUR cents without floating point", () => {
    expect(formatMollieAmount(12500)).toBe("125.00");
    expect(parseMollieAmountCents({ currency: "EUR", value: "125.00" })).toBe(12500);
    expect(() => parseMollieAmountCents({ currency: "USD", value: "125.00" })).toThrow();
  });

  it("requires exact internal metadata", () => {
    expect(parseMollieMetadata(JSON.stringify(metadata))).toEqual(metadata);
    expect(parseMollieMetadata({
      payment_id: metadata.payment_id,
      order_id: metadata.order_id,
      member_id: metadata.member_id,
      season_id: metadata.season_id,
      schema_version: 1,
    })).toEqual({
      payment_id: metadata.payment_id,
      order_id: metadata.order_id,
      member_id: metadata.member_id,
      season_id: metadata.season_id,
      schema_version: 1,
    });
    expect(() => parseMollieMetadata({ ...metadata, order_id: "wrong" })).toThrow("MOLLIE_METADATA_INVALID");
  });

  it("creates a hosted payment with idempotency and no order lines", async () => {
    const fetcher = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      const body = JSON.parse(String(init?.body));
      expect(init?.headers).toMatchObject({ "Idempotency-Key": "attempt-key" });
      expect(body.amount).toEqual({ currency: "EUR", value: "125.00" });
      expect(body.lines).toBeUndefined();
      return new Response(JSON.stringify({ id: "tr_test123", status: "open", amount: body.amount, metadata, _links: { checkout: { href: "https://www.mollie.com/checkout/test" } } }), { status: 201 });
    });
    const result = await createMolliePayment({ apiKey: "test_key", idempotencyKey: "attempt-key", amountCents: 12500, description: "Duindorp SV bestelling", redirectUrl: "https://example.test/betaling/terug", webhookUrl: "https://example.test/api/webhooks/mollie", metadata }, fetcher as typeof fetch);
    expect(result._links.checkout?.href).toContain("mollie.com");
  });

  it("accepts uitsluitend het klassieke Mollie-formulier", async () => {
    await expect(extractMollieWebhookPaymentId(new Request("https://example.test", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: "id=tr_abc123" }))).resolves.toBe("tr_abc123");
    await expect(extractMollieWebhookPaymentId(new Request("https://example.test", { method: "POST", headers: { "content-type": "application/json" }, body: '{"id":"tr_abc123"}' }))).rejects.toThrow("MOLLIE_WEBHOOK_CONTENT_TYPE_INVALID");
  });

  it("keeps partial refund resources separate from the factual payment status", () => {
    const base = { id: "tr_test123", status: "authorized", amount: { currency: "EUR", value: "125.00" }, metadata, _links: {} };
    const authorized = molliePaymentSchema.parse(base);
    const refunded = molliePaymentSchema.parse({ ...base, status: "paid", amountRefunded: { currency: "EUR", value: "125.00" } });
    expect(toLocalMollieStatus(authorized)).toBe("pending");
    expect(toLocalMollieStatus(refunded)).toBe("paid");
  });

  it("never turns a partial embedded refund into a whole-payment refund", () => {
    const base = { id: "tr_test123", status: "paid", amount: { currency: "EUR", value: "125.00" }, metadata, _links: {} };
    const withRefund = (status: "queued" | "processing" | "refunded") => molliePaymentSchema.parse({
      ...base,
      _embedded: { refunds: [{ id: "re_test123", status, amount: { currency: "EUR", value: "125.00" } }] },
    });
    expect(toLocalMollieStatus(withRefund("queued"))).toBe("paid");
    expect(toLocalMollieStatus(withRefund("processing"))).toBe("paid");
    expect(toLocalMollieStatus(withRefund("refunded"))).toBe("paid");
  });

  it("creates an exact idempotent partial refund with package metadata", async () => {
    const fetcher = vi.fn(async (_url: string | URL | Request, init?: RequestInit) => {
      const body = JSON.parse(String(init?.body));
      expect(init?.headers).toMatchObject({ "Idempotency-Key": "package-refund:key" });
      expect(body.amount).toEqual({ currency: "EUR", value: "7.50" });
      return new Response(JSON.stringify({
        id: "re_test123", status: "pending", paymentId: "tr_test123",
        amount: body.amount, metadata: body.metadata,
      }), { status: 201 });
    });
    await expect(createMollieRefund({
      apiKey: "test_key", providerPaymentId: "tr_test123",
      idempotencyKey: "package-refund:key", amountCents: 750,
      description: "Pakketcorrectie",
      metadata: { package_refund_id: metadata.payment_id, schema_version: 1 },
    }, fetcher as typeof fetch)).resolves.toMatchObject({ id: "re_test123", status: "pending" });
  });

  it("fetches the payment together with authoritative refund resources", async () => {
    const fetcher = vi.fn(async (url: string | URL | Request) => {
      if (String(url).endsWith("/refunds?limit=250")) {
        return new Response(JSON.stringify({
          _embedded: { refunds: [{ id: "re_test123", status: "refunded", amount: { currency: "EUR", value: "125.00" } }] },
        }), { status: 200 });
      }
      expect(String(url)).toBe("https://api.mollie.com/v2/payments/tr_test123");
      return new Response(JSON.stringify({
        id: "tr_test123",
        status: "paid",
        amount: { currency: "EUR", value: "125.00" },
        metadata,
        _links: {},
      }), { status: 200 });
    });
    await expect(getMolliePayment("test_key", "tr_test123", fetcher as typeof fetch)).resolves.toMatchObject({
      id: "tr_test123",
      _embedded: { refunds: [{ id: "re_test123", status: "refunded" }] },
    });
    expect(fetcher).toHaveBeenCalledTimes(2);
  });

  it("begrensd ook een chunked antwoord van de Mollie API vóór JSON-parsing", async () => {
    const fetcher = vi.fn(async () => new Response(new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new Uint8Array(100_001));
        controller.close();
      },
    }), { status: 200 }));

    await expect(getMolliePayment("test_key", "tr_test123", fetcher as typeof fetch))
      .rejects.toThrow("MOLLIE_RESPONSE_TOO_LARGE");
  });

  it("accepts checkout links only from Mollie over HTTPS", () => {
    const base = { id: "tr_test123", status: "open", amount: { currency: "EUR", value: "125.00" }, metadata };
    expect(requireHostedCheckoutUrl(molliePaymentSchema.parse({ ...base, _links: { checkout: { href: "https://checkout.mollie.com/pay/test" } } }))).toContain("checkout.mollie.com");
    expect(() => requireHostedCheckoutUrl(molliePaymentSchema.parse({ ...base, _links: { checkout: { href: "https://evil.example/pay/test" } } }))).toThrow("MOLLIE_CHECKOUT_INVALID");
  });
});
