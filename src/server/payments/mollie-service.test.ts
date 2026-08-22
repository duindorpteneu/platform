import { describe, expect, it, vi } from "vitest";
import { hasTrustedPaymentOrigin, reconcileMollieWebhook, startMollieCheckout, startMollieRefund, type MollieRpcClient } from "@/server/payments/mollie-service";
import { MollieRequestError } from "@/server/payments/mollie";

const ids = {
  payment: "00000000-0000-4000-8000-000000000001",
  order: "00000000-0000-4000-8000-000000000002",
  member: "00000000-0000-4000-8000-000000000003",
  season: "00000000-0000-4000-8000-000000000004",
  memberSeason: "00000000-0000-4000-8000-000000000005",
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
    member_season_id: ids.memberSeason,
    season_id: ids.season,
    schema_version: 2,
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
  metadataSchemaVersion: 2,
  orderId: ids.order,
  memberId: ids.member,
  memberSeasonId: ids.memberSeason,
  seasonId: ids.season,
  amountDueCents: 7500,
} as const;
const refundStaff = {
  actorUserId: "00000000-0000-4000-8000-000000000007",
  staffSessionHash: "c".repeat(64),
};

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
  it("maakt een partial refund eenmaal met de duurzame database-idempotencykey", async () => {
    const refundId = "00000000-0000-4000-8000-000000000006";
    const appRpc = vi.fn()
      .mockResolvedValueOnce({ data: {
        refundId, paymentId: ids.payment, providerPaymentId: "tr_test123",
        providerRefundId: null, amountCents: 750, currency: "EUR",
        status: "requesting", idempotencyKey: `package-refund:${refundId}`, reused: false,
      }, error: null })
      .mockResolvedValueOnce({ data: {
        refundId, providerRefundId: "re_test123", status: "pending",
        providerStatus: "pending", amountCents: 750, currency: "EUR",
      }, error: null });
    const createRefund = vi.fn().mockResolvedValue({
      id: "re_test123", status: "pending", paymentId: "tr_test123",
      amount: { currency: "EUR", value: "7.50" },
      metadata: { package_refund_id: refundId, schema_version: 1 },
    });
    await expect(startMollieRefund({
      refundId,
      requestId: refundId,
      ...refundStaff,
    }, {
      database: databaseWithAppRpc(appRpc).database, config, createRefund,
      now: new Date("2026-08-20T12:00:00Z"),
    })).resolves.toMatchObject({ providerRefundId: "re_test123", status: "pending" });
    expect(createRefund).toHaveBeenCalledWith(expect.objectContaining({
      amountCents: 750, idempotencyKey: `package-refund:${refundId}`,
      providerPaymentId: "tr_test123",
    }));
    expect(appRpc).toHaveBeenNthCalledWith(1, "prepare_mollie_refund_v1", expect.objectContaining({
      p_actor_user_id: refundStaff.actorUserId,
      p_staff_session_hash: refundStaff.staffSessionHash,
    }));
    expect(appRpc).toHaveBeenNthCalledWith(2, "bind_mollie_refund_v1", expect.objectContaining({
      p_provider_refund_id: "re_test123", p_provider_status: "pending",
    }));
  });

  it("houdt een reeds door Mollie gemaakte refund retrybaar wanneer lokaal binden tijdelijk faalt", async () => {
    const refundId = "00000000-0000-4000-8000-000000000006";
    const appRpc = vi.fn()
      .mockResolvedValueOnce({ data: {
        refundId, paymentId: ids.payment, providerPaymentId: "tr_test123",
        providerRefundId: null, amountCents: 750, currency: "EUR",
        status: "requesting", idempotencyKey: `package-refund:${refundId}`, reused: false,
      }, error: null })
      .mockResolvedValueOnce({ data: null, error: { message: "temporary database failure" } })
      .mockResolvedValueOnce({ data: { refundId, status: "failed", retryable: true }, error: null });
    const createRefund = vi.fn().mockResolvedValue({
      id: "re_test123", status: "pending", paymentId: "tr_test123",
      amount: { currency: "EUR", value: "7.50" },
      metadata: { package_refund_id: refundId, schema_version: 1 },
    });

    await expect(startMollieRefund({
      refundId,
      requestId: refundId,
      ...refundStaff,
    }, {
      database: databaseWithAppRpc(appRpc).database, config, createRefund,
      now: new Date("2026-08-20T12:00:00Z"),
    })).rejects.toMatchObject({ code: "DATABASE_UNAVAILABLE", retryable: true });

    expect(appRpc).toHaveBeenNthCalledWith(3, "fail_mollie_refund_v1", expect.objectContaining({
      p_failure_code: "MOLLIE_REFUND_BIND_UNAVAILABLE",
      p_retryable: true,
    }));
  });

  it.each([
    ["provider-timeout", new DOMException("timeout", "TimeoutError")],
    ["ongeldige providersuccessrespons", new Error("MOLLIE_REFUND_RESPONSE_MISMATCH")],
  ])("houdt een onzekere %s met dezelfde idempotencykey retrybaar", async (_label, providerError) => {
    const refundId = "00000000-0000-4000-8000-000000000006";
    const appRpc = vi.fn()
      .mockResolvedValueOnce({ data: {
        refundId, paymentId: ids.payment, providerPaymentId: "tr_test123",
        providerRefundId: null, amountCents: 750, currency: "EUR",
        status: "requesting", idempotencyKey: `package-refund:${refundId}`, reused: false,
      }, error: null })
      .mockResolvedValueOnce({ data: { refundId, status: "failed", retryable: true }, error: null });
    const createRefund = vi.fn().mockRejectedValue(providerError);

    await expect(startMollieRefund({
      refundId,
      requestId: refundId,
      ...refundStaff,
    }, {
      database: databaseWithAppRpc(appRpc).database,
      config,
      createRefund,
      now: new Date("2026-08-20T12:00:00Z"),
    })).rejects.toMatchObject({
      code: "INVALID_PROVIDER_RESPONSE",
      retryable: true,
    });

    expect(createRefund).toHaveBeenCalledWith(expect.objectContaining({
      idempotencyKey: `package-refund:${refundId}`,
    }));
    expect(appRpc).toHaveBeenNthCalledWith(2, "fail_mollie_refund_v1", expect.objectContaining({
      p_failure_code: "MOLLIE_PROVIDER_UNAVAILABLE",
      p_retryable: true,
    }));
  });

  it("markeert een definitieve provider-4xx als terminaal", async () => {
    const refundId = "00000000-0000-4000-8000-000000000006";
    const appRpc = vi.fn()
      .mockResolvedValueOnce({ data: {
        refundId, paymentId: ids.payment, providerPaymentId: "tr_test123",
        providerRefundId: null, amountCents: 750, currency: "EUR",
        status: "requesting", idempotencyKey: `package-refund:${refundId}`, reused: false,
      }, error: null })
      .mockResolvedValueOnce({ data: { refundId, status: "failed", retryable: false }, error: null });

    await expect(startMollieRefund({
      refundId,
      requestId: refundId,
      ...refundStaff,
    }, {
      database: databaseWithAppRpc(appRpc).database,
      config,
      createRefund: vi.fn().mockRejectedValue(new MollieRequestError(422, false)),
    })).rejects.toMatchObject({
      code: "PROVIDER_UNAVAILABLE",
      retryable: false,
    });

    expect(appRpc).toHaveBeenNthCalledWith(2, "fail_mollie_refund_v1", expect.objectContaining({
      p_failure_code: "MOLLIE_REFUND_RESPONSE_INVALID",
      p_retryable: false,
    }));
  });

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

  it("start geen providerbetaling wanneer pakketmaten ontbreken", async () => {
    const publicRpc = vi.fn().mockResolvedValue({
      data: null,
      error: { code: "23514", message: "PACKAGE_SIZES_REQUIRED" },
    });
    const createPayment = vi.fn();
    await expect(startMollieCheckout(
      { tokenHash: "a".repeat(64), orderId: ids.order, idempotencyKey: "missing-sizes" },
      { database: { rpc: publicRpc, schema: vi.fn() } as MollieRpcClient, config, createPayment },
    )).rejects.toMatchObject({ code: "PACKAGE_SIZES_REQUIRED", retryable: false });
    expect(createPayment).not.toHaveBeenCalled();
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
    expect(rpc).toHaveBeenLastCalledWith("reconcile_mollie_payment_v3", expect.objectContaining({
      p_event_key: expect.stringMatching(/^mollie:[0-9a-f]{64}$/),
      p_status: "paid",
      p_local_payment_id: ids.payment,
      p_metadata_payment_id: ids.payment,
      p_member_season_id: ids.memberSeason,
      p_observation: { schema_version: 2 },
    }));
    expect(rpc).toHaveBeenNthCalledWith(1, "get_mollie_reconciliation_context_v2", {
      p_provider_id: "tr_test123",
    });
  });

  it("reconcileert een embedded partial refund apart terwijl de betaling paid blijft", async () => {
    process.env.PARENT_TOKEN_PEPPER = "p".repeat(32);
    const rpc = vi.fn()
      .mockResolvedValueOnce({ data: { ...context, paymentStatus: "paid" }, error: null })
      .mockResolvedValueOnce({ data: { paymentId: ids.payment, orderId: ids.order, status: "paid", effect: "already_processed", eventType: "replay" }, error: null })
      .mockResolvedValueOnce({ data: { paymentId: ids.payment, orderId: ids.order, updatedCount: 1 }, error: null });
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

    expect(rpc).toHaveBeenNthCalledWith(2, "reconcile_mollie_payment_v3", expect.objectContaining({
      p_status: "paid", p_refunded_at: null,
    }));
    expect(rpc).toHaveBeenLastCalledWith("reconcile_mollie_refunds_v1", expect.objectContaining({
      p_provider_payment_id: "tr_test123",
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

    expect(rpc).toHaveBeenLastCalledWith("reconcile_mollie_payment_v3", expect.objectContaining({
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

    expect(rpc).toHaveBeenLastCalledWith("reconcile_mollie_payment_v3", expect.objectContaining({ p_status: "pending" }));
  });

  it("ondersteunt een historische v1-providerpoging zonder member-season-downgrade", async () => {
    const legacyMetadata = {
      payment_id: ids.payment,
      order_id: ids.order,
      member_id: ids.member,
      season_id: ids.season,
      schema_version: 1 as const,
    };
    const rpc = vi.fn()
      .mockResolvedValueOnce({
        data: { ...context, metadataSchemaVersion: 1 },
        error: null,
      })
      .mockResolvedValueOnce({
        data: {
          paymentId: ids.payment,
          orderId: ids.order,
          status: "paid",
          effect: "paid",
          eventType: "paid",
        },
        error: null,
      });

    await reconcileMollieWebhook("tr_test123", {
      database: databaseWithAppRpc(rpc).database,
      config,
      getPayment: vi.fn().mockResolvedValue(providerPayment({ metadata: legacyMetadata })),
    });

    expect(rpc).toHaveBeenLastCalledWith("reconcile_mollie_payment_v3", expect.objectContaining({
      p_member_season_id: ids.memberSeason,
      p_observation: { schema_version: 1 },
    }));
  });
});
