import { describe, expect, it, vi } from "vitest";
import { hasTrustedPaymentOrigin, reconcileMollieWebhook, startMollieCheckout, type MollieRpcClient } from "@/server/payments/mollie-service";

const ids = {
  payment: "00000000-0000-4000-8000-000000000001",
  order: "00000000-0000-4000-8000-000000000002",
  member: "00000000-0000-4000-8000-000000000003",
  season: "00000000-0000-4000-8000-000000000004",
};

const prepared = {
  paymentId: ids.payment,
  orderId: ids.order,
  amountCents: 7500,
  currency: "EUR",
  status: "open",
  providerPaymentId: null,
  checkoutUrl: null,
  reused: false,
  idempotencyKey: "00000000-0000-4000-8000-000000000099",
  metadata: {
    payment_id: ids.payment,
    order_id: ids.order,
    member_id: ids.member,
    season_id: ids.season,
    schema_version: 1,
  },
} as const;

function databaseWith(data = prepared) {
  const publicRpc = vi.fn().mockResolvedValueOnce({ data, error: null });
  const appRpc = vi.fn().mockResolvedValueOnce({ data: { paymentId: ids.payment }, error: null });
  const schema = vi.fn().mockReturnValue({ rpc: appRpc });
  return { database: { rpc: publicRpc, schema } as MollieRpcClient, publicRpc, appRpc, schema };
}

function databaseWithAppRpc(appRpc: ReturnType<typeof vi.fn>, publicRpc = vi.fn()) {
  const schema = vi.fn().mockReturnValue({ rpc: appRpc });
  return { database: { rpc: publicRpc, schema } as MollieRpcClient, publicRpc, appRpc, schema };
}

const config = { enabled: true, apiKey: "test_0000000000000000", appBaseUrl: "https://tenue.duindorpsv.nl" } as const;
const context = {
  paymentId: ids.payment,
  providerPaymentId: "tr_test123",
  paymentStatus: "open",
  amountCents: 7500,
  currency: "EUR",
  orderId: ids.order,
  memberId: ids.member,
  seasonId: ids.season,
  amountDueCents: 7500,
  qrVersion: 0,
  activeQrVersion: null,
} as const;

function providerPayment(overrides: Record<string, unknown> = {}) {
  return {
    id: "tr_test123",
    status: "paid",
    amount: { currency: "EUR", value: "75.00" },
    metadata: prepared.metadata,
    createdAt: "2026-07-18T11:00:00Z",
    paidAt: "2026-07-18T11:05:00Z",
    _links: {},
    ...overrides,
  };
}

describe("Mollie-applicatieservice", () => {
  it("controleert de origin exact tegen de applicatie-origin", () => {
    expect(hasTrustedPaymentOrigin(new Request("https://tenue.duindorpsv.nl/api", { headers: { origin: "https://tenue.duindorpsv.nl" } }), config.appBaseUrl)).toBe(true);
    expect(hasTrustedPaymentOrigin(new Request("https://tenue.duindorpsv.nl/api", { headers: { origin: "https://aanvaller.invalid" } }), config.appBaseUrl)).toBe(false);
  });

  it("hergebruikt een bestaande beveiligde checkout zonder providercall", async () => {
    const existing = { ...prepared, checkoutUrl: "https://www.mollie.com/checkout/existing", reused: true };
    const rpc = vi.fn().mockResolvedValue({ data: existing, error: null });
    const schema = vi.fn();
    const createPayment = vi.fn();

    await expect(startMollieCheckout({ tokenHash: "a".repeat(64), orderId: ids.order, idempotencyKey: "attempt-key" }, {
      database: { rpc, schema } as MollieRpcClient,
      config,
      createPayment,
    })).resolves.toEqual({ checkoutUrl: existing.checkoutUrl });
    expect(createPayment).not.toHaveBeenCalled();
    expect(schema).not.toHaveBeenCalled();
  });

  it("laat het browserbedrag buiten beschouwing en bindt de providerpoging", async () => {
    const { database, publicRpc, appRpc, schema } = databaseWith();
    const createPayment = vi.fn().mockResolvedValue({
      id: "tr_test123",
      status: "open",
      amount: { currency: "EUR", value: "75.00" },
      metadata: prepared.metadata,
      expiresAt: "2026-07-18T13:00:00Z",
      _links: { checkout: { href: "https://www.mollie.com/checkout/new" } },
    });

    const result = await startMollieCheckout({ tokenHash: "a".repeat(64), orderId: ids.order, idempotencyKey: "new-attempt" }, {
      database,
      config,
      createPayment,
    });

    expect(result.checkoutUrl).toBe("https://www.mollie.com/checkout/new");
    expect(createPayment).toHaveBeenCalledWith(expect.objectContaining({
      amountCents: 7500,
      idempotencyKey: prepared.idempotencyKey,
      metadata: prepared.metadata,
      redirectUrl: "https://tenue.duindorpsv.nl/betaling/terug",
      webhookUrl: "https://tenue.duindorpsv.nl/api/webhooks/mollie",
    }));
    expect(publicRpc).toHaveBeenCalledWith("prepare_mollie_payment", expect.any(Object));
    expect(schema).toHaveBeenCalledWith("app");
    expect(appRpc).toHaveBeenLastCalledWith("bind_mollie_payment", expect.objectContaining({
      p_payment_id: ids.payment,
      p_provider_id: "tr_test123",
      p_checkout_url: "https://www.mollie.com/checkout/new",
    }));
  });

  it("weigert een onveilige provider-checkout", async () => {
    const { database } = databaseWith();
    const createPayment = vi.fn().mockResolvedValue({
      id: "tr_test123",
      status: "open",
      amount: { currency: "EUR", value: "75.00" },
      metadata: prepared.metadata,
      _links: { checkout: { href: "http://mollie.test/checkout" } },
    });

    await expect(startMollieCheckout({ tokenHash: "a".repeat(64), orderId: ids.order, idempotencyKey: "new-attempt" }, {
      database,
      config,
      createPayment,
    })).rejects.toMatchObject({ code: "INVALID_PROVIDER_RESPONSE" });
  });

  it("bindt een authorized checkout uitsluitend als lokale pending-status", async () => {
    const { database, appRpc } = databaseWith();
    const createPayment = vi.fn().mockResolvedValue({
      ...providerPayment({ status: "authorized", paidAt: null }),
      _links: { checkout: { href: "https://checkout.mollie.com/pay/authorized" } },
    });

    await startMollieCheckout({ tokenHash: "a".repeat(64), orderId: ids.order, idempotencyKey: "authorized-attempt" }, {
      database,
      config,
      createPayment,
    });

    expect(appRpc).toHaveBeenLastCalledWith("bind_mollie_payment", expect.objectContaining({ p_status: "pending" }));
  });

  it("geeft een deterministische event-key en alleen geredigeerde observatie door", async () => {
    process.env.PARENT_TOKEN_PEPPER = "p".repeat(32);
    const rpc = vi.fn()
      .mockResolvedValueOnce({ data: context, error: null })
      .mockResolvedValueOnce({ data: { paymentId: ids.payment, orderId: ids.order, status: "paid", effect: "paid", eventType: "paid" }, error: null });
    const { database, publicRpc, schema } = databaseWithAppRpc(rpc);
    const getPayment = vi.fn().mockResolvedValue(providerPayment());

    await reconcileMollieWebhook("tr_test123", {
      database,
      config,
      getPayment,
      receivedAt: new Date("2026-07-18T11:06:00Z"),
    });

    expect(getPayment).toHaveBeenCalledWith(config.apiKey, "tr_test123");
    expect(publicRpc).not.toHaveBeenCalled();
    expect(schema).toHaveBeenCalledWith("app");
    expect(rpc).toHaveBeenLastCalledWith("reconcile_mollie_payment", expect.objectContaining({
      p_event_key: expect.stringMatching(/^mollie:[0-9a-f]{64}$/),
      p_status: "paid",
      p_local_payment_id: ids.payment,
      p_metadata_payment_id: ids.payment,
      p_observation: { schema_version: 1 },
      p_token_hash: expect.stringMatching(/^[0-9a-f]{64}$/),
    }));
  });

  it("behandelt een embedded providerrefund fail-closed als refunded", async () => {
    process.env.PARENT_TOKEN_PEPPER = "p".repeat(32);
    const rpc = vi.fn()
      .mockResolvedValueOnce({ data: { ...context, paymentStatus: "paid", qrVersion: 1, activeQrVersion: 1 }, error: null })
      .mockResolvedValueOnce({ data: { paymentId: ids.payment, orderId: ids.order, status: "refunded", effect: "refunded", eventType: "refunded" }, error: null });
    const getPayment = vi.fn().mockResolvedValue(providerPayment({
      _embedded: {
        refunds: [{ id: "re_test123", status: "refunded", amount: { currency: "EUR", value: "1.00" } }],
      },
    }));
    const { database } = databaseWithAppRpc(rpc);

    await reconcileMollieWebhook("tr_test123", {
      database,
      config,
      getPayment,
      receivedAt: new Date("2026-07-18T12:00:00Z"),
    });

    expect(rpc).toHaveBeenLastCalledWith("reconcile_mollie_payment", expect.objectContaining({
      p_status: "refunded",
      p_refunded_at: "2026-07-18T12:00:00.000Z",
    }));
  });

  it("accepteert een ledger-replay als succesvol idempotent resultaat", async () => {
    process.env.PARENT_TOKEN_PEPPER = "p".repeat(32);
    const rpc = vi.fn()
      .mockResolvedValueOnce({ data: context, error: null })
      .mockResolvedValueOnce({ data: { paymentId: ids.payment, status: "replay", effect: "event_replay", eventType: "paid" }, error: null });

    const { database } = databaseWithAppRpc(rpc);

    await expect(reconcileMollieWebhook("tr_test123", {
      database,
      config,
      getPayment: vi.fn().mockResolvedValue(providerPayment()),
    })).resolves.toMatchObject({ effect: "event_replay" });
  });

  it("stuurt malformed metadata naar het transactionele manual-reviewpad", async () => {
    process.env.PARENT_TOKEN_PEPPER = "p".repeat(32);
    const rpc = vi.fn()
      .mockResolvedValueOnce({ data: context, error: null })
      .mockResolvedValueOnce({ data: { paymentId: ids.payment, status: "manual_review", effect: "mismatch", issue: "MOLLIE_METADATA_INVALID" }, error: null });

    const { database } = databaseWithAppRpc(rpc);

    await expect(reconcileMollieWebhook("tr_test123", {
      database,
      config,
      getPayment: vi.fn().mockResolvedValue(providerPayment({ metadata: "niet-geldige-json" })),
    })).resolves.toMatchObject({ effect: "mismatch", status: "manual_review" });

    expect(rpc).toHaveBeenLastCalledWith("reconcile_mollie_payment", expect.objectContaining({
      p_local_payment_id: ids.payment,
      p_metadata_payment_id: null,
      p_order_id: ids.order,
      p_validation_issue: "MOLLIE_METADATA_INVALID",
      p_observation: {},
    }));
  });

  it("geeft authorized nooit door aan de database-enum", async () => {
    process.env.PARENT_TOKEN_PEPPER = "p".repeat(32);
    const rpc = vi.fn()
      .mockResolvedValueOnce({ data: context, error: null })
      .mockResolvedValueOnce({ data: { paymentId: ids.payment, orderId: ids.order, status: "pending", effect: "updated", eventType: "observed" }, error: null });

    const { database } = databaseWithAppRpc(rpc);

    await reconcileMollieWebhook("tr_test123", {
      database,
      config,
      getPayment: vi.fn().mockResolvedValue(providerPayment({ status: "authorized", paidAt: null })),
    });

    expect(rpc).toHaveBeenLastCalledWith("reconcile_mollie_payment", expect.objectContaining({ p_status: "pending" }));
  });
});
