import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";
// @ts-expect-error The production acceptance entrypoint intentionally uses plain Node.js ESM.
import * as acceptance from "./mollie-staging-acceptance.mjs";

const {
  ACCEPTANCE_CONFIRMATION,
  POSTGRES_IMAGE,
  STAGING_SUPABASE_PROJECT_REF,
  assertMismatchSnapshot,
  assertPaidSnapshot,
  assertReadinessSnapshot,
  assertRefundSnapshot,
  choosePaidOnHostedTestPage,
  chooseRefundedOnHostedTestPage,
  createFixtureIdentity,
  isTerminalFullRefund,
  postConcurrentReplays,
  providerRequest,
  runFixtureSql,
  stagingParentRpc,
  validateCheckoutUrl,
  validateConfiguration,
  validateTargetConfiguration,
} = acceptance;

const validEnv = {
  APP_BASE_URL: "https://staging-duindorp.dgwebservices.nl",
  EXPECTED_STAGING_SUPABASE_PROJECT_REF: STAGING_SUPABASE_PROJECT_REF,
  SUPABASE_DB_URL: `postgresql://postgres:secret@db.${STAGING_SUPABASE_PROJECT_REF}.supabase.co:5432/postgres?sslmode=require`,
  SUPABASE_SERVICE_ROLE_KEY: "service-role-key-with-at-least-forty-characters-for-tests",
  MOLLIE_ACCEPTANCE_RUN_ID: "123456789-1",
  RELEASE_SHA: "a".repeat(40),
  MOLLIE_API_KEY: "test_example-key-with-enough-entropy",
  MOLLIE_PROFILE_ID: "pfl_Example123",
  PARENT_TOKEN_PEPPER: "p".repeat(32),
  MOLLIE_ACCEPTANCE_CONFIRMATION: ACCEPTANCE_CONFIRMATION,
};

describe("Mollie staging acceptance guards", () => {
  it("accepts only the exact staging target, revision, test key and expected profile", () => {
    expect(validateConfiguration(validEnv)).toMatchObject({
      appBaseUrl: validEnv.APP_BASE_URL,
      releaseSha: validEnv.RELEASE_SHA,
      profileId: validEnv.MOLLIE_PROFILE_ID,
    });

    expect(() => validateConfiguration({ ...validEnv, APP_BASE_URL: "https://duindorp.dgwebservices.nl" }))
      .toThrow("MOLLIE_ACCEPTANCE_STAGING_HOST_REQUIRED");
    expect(() => validateConfiguration({ ...validEnv, MOLLIE_API_KEY: "live_forbidden" }))
      .toThrow("MOLLIE_ACCEPTANCE_TEST_KEY_REQUIRED");
    expect(() => validateConfiguration({ ...validEnv, RELEASE_SHA: "main" }))
      .toThrow("MOLLIE_ACCEPTANCE_RELEASE_SHA_INVALID");
    expect(() => validateConfiguration({ ...validEnv, MOLLIE_PROFILE_ID: "pfl_wrong profile" }))
      .toThrow("MOLLIE_ACCEPTANCE_PROFILE_ID_INVALID");
    expect(() => validateConfiguration({ ...validEnv, SUPABASE_SERVICE_ROLE_KEY: "" }))
      .toThrow("MOLLIE_ACCEPTANCE_SERVICE_ROLE_KEY_INVALID");
    expect(() => validateConfiguration({ ...validEnv, MOLLIE_ACCEPTANCE_CONFIRMATION: "yes" }))
      .toThrow("MOLLIE_ACCEPTANCE_CONFIRMATION_REQUIRED");
  });

  it("binds direct and pooler database URLs to the exact staging project ref", () => {
    expect(validateTargetConfiguration({
      ...validEnv,
      SUPABASE_DB_URL: `postgresql://postgres.${STAGING_SUPABASE_PROJECT_REF}:secret@aws-0-eu-central-1.pooler.supabase.com:6543/postgres?sslmode=require`,
    }).projectRef).toBe(STAGING_SUPABASE_PROJECT_REF);

    expect(() => validateTargetConfiguration({
      ...validEnv,
      EXPECTED_STAGING_SUPABASE_PROJECT_REF: "abcdefghijklmnopqrst",
      SUPABASE_DB_URL: "postgresql://postgres:secret@db.abcdefghijklmnopqrst.supabase.co:5432/postgres?sslmode=require",
    })).toThrow("MOLLIE_ACCEPTANCE_PROJECT_REF_MISMATCH");

    expect(() => validateTargetConfiguration({
      ...validEnv,
      SUPABASE_DB_URL: "postgresql://postgres:secret@db.zzzzzzzzzzzzzzzzzzzz.supabase.co:5432/postgres?sslmode=require",
    })).toThrow("MOLLIE_ACCEPTANCE_DATABASE_TARGET_MISMATCH");
    expect(() => validateTargetConfiguration({
      ...validEnv,
      SUPABASE_DB_URL: `postgresql://postgres:secret@db.${STAGING_SUPABASE_PROJECT_REF}.supabase.co:5432/postgres?sslmode=disable`,
    })).toThrow("MOLLIE_ACCEPTANCE_DATABASE_TLS_REQUIRED");
    expect(() => validateTargetConfiguration({
      ...validEnv,
      SUPABASE_DB_URL: `postgresql://postgres:secret@db.${STAGING_SUPABASE_PROJECT_REF}.supabase.co:5432/postgres?sslmode=prefer`,
    })).toThrow("MOLLIE_ACCEPTANCE_DATABASE_TLS_REQUIRED");
    expect(() => validateTargetConfiguration({
      ...validEnv,
      SUPABASE_DB_URL: `postgresql://postgres:secret@db.${STAGING_SUPABASE_PROJECT_REF}.supabase.co:5432/postgres`,
    })).toThrow("MOLLIE_ACCEPTANCE_DATABASE_TLS_REQUIRED");
    expect(() => validateTargetConfiguration({
      ...validEnv,
      SUPABASE_DB_URL: `postgresql://readonly:secret@db.${STAGING_SUPABASE_PROJECT_REF}.supabase.co:5432/postgres?sslmode=require`,
    })).toThrow("MOLLIE_ACCEPTANCE_DATABASE_TARGET_MISMATCH");
  });

  it("creates deterministic, fictitious and run-isolated fixture identities", () => {
    const first = createFixtureIdentity(validEnv.MOLLIE_ACCEPTANCE_RUN_ID);
    expect(createFixtureIdentity(validEnv.MOLLIE_ACCEPTANCE_RUN_ID)).toEqual(first);
    expect(createFixtureIdentity("123456789-2")).not.toEqual(first);
    expect(first.fixtureEmail).toMatch(/@example\.invalid$/);
    expect(first.paidOrderId).toMatch(/^[0-9a-f-]{36}$/);
    expect(first.readinessArticleId).toMatch(/^[0-9a-f-]{36}$/);
    expect(new Set([
      first.paidMemberId,
      first.mismatchMemberId,
      first.paidOrderId,
      first.mismatchOrderId,
      first.readinessArticleId,
      first.readinessVariantId,
      first.readinessOrderLineId,
      first.readinessQrRequestId,
    ])).toHaveProperty("size", 8);
  });

  it("runs fixture SQL in a pinned least-privilege container without a database URL in arguments", () => {
    const identity = createFixtureIdentity(validEnv.MOLLIE_ACCEPTANCE_RUN_ID);
    const spawnImpl = vi.fn().mockReturnValue({
      status: 0,
      stdout: '{"prepared":true}\n',
    });

    expect(runFixtureSql(
      { dbUrl: validEnv.SUPABASE_DB_URL },
      "prepare",
      identity,
      { spawnImpl },
    )).toEqual({ prepared: true });

    expect(spawnImpl).toHaveBeenCalledOnce();
    const [executable, args, options] = spawnImpl.mock.calls[0];
    expect(executable).toBe("docker");
    expect(args).toContain(POSTGRES_IMAGE);
    expect(args).toContain("--read-only");
    expect(args).toContain("--cap-drop=ALL");
    expect(args.join(" ")).not.toContain(validEnv.SUPABASE_DB_URL);
    expect(args.join(" ")).not.toContain("secret@");
    expect(options.env.TARGET_DB_URL).toBe(validEnv.SUPABASE_DB_URL);
    expect(options.stdio).toEqual(["pipe", "pipe", "ignore"]);
  });

  it("runs the readiness proof through the isolated SQL harness", () => {
    const identity = createFixtureIdentity(validEnv.MOLLIE_ACCEPTANCE_RUN_ID);
    const spawnImpl = vi.fn().mockReturnValue({
      status: 0,
      stdout: '{"transactionRolledBack":true}\n',
    });

    expect(runFixtureSql(
      { dbUrl: validEnv.SUPABASE_DB_URL },
      "readiness",
      identity,
      { spawnImpl },
    )).toEqual({ transactionRolledBack: true });
    const [, args, options] = spawnImpl.mock.calls[0];
    expect(args).toContain("--env");
    expect(args).toContain("FIXTURE_READINESS_ARTICLE_ID");
    expect(options.env.FIXTURE_READINESS_ORDER_LINE_ID).toBe(identity.readinessOrderLineId);
  });

  it("keeps the readiness inventory, allocation and QR proof rollback-only", () => {
    const sql = readFileSync(
      new URL("./sql/mollie-fixture-readiness.sql", import.meta.url),
      "utf8",
    );
    expect(sql).toContain("private.allocate_inventory_fifo_variant(");
    expect(sql).toContain("app.register_order_qr_locator(");
    expect(sql).toContain("'transactionRolledBack', true");
    expect(sql.trim().endsWith("rollback;")).toBe(true);
    expect(sql).not.toMatch(/\bcommit\s*;/i);
  });

  it("allows state reads only for an exact fixture order/member pair", () => {
    const identity = createFixtureIdentity(validEnv.MOLLIE_ACCEPTANCE_RUN_ID);
    expect(() => runFixtureSql(
      { dbUrl: validEnv.SUPABASE_DB_URL },
      "state",
      identity,
      {
        stateIdentity: {
          orderId: identity.paidOrderId,
          memberId: identity.mismatchMemberId,
        },
        spawnImpl: vi.fn(),
      },
    )).toThrow("MOLLIE_ACCEPTANCE_FIXTURE_STATE_IDENTITY_INVALID");
  });

  it("rejects non-Mollie and insecure checkout URLs", () => {
    expect(validateCheckoutUrl("https://www.mollie.com/checkout/test")).toBe("https://www.mollie.com/checkout/test");
    expect(() => validateCheckoutUrl("https://mollie.com.evil.invalid/checkout")).toThrow("MOLLIE_ACCEPTANCE_CHECKOUT_URL_INVALID");
    expect(() => validateCheckoutUrl("http://www.mollie.com/checkout")).toThrow("MOLLIE_ACCEPTANCE_CHECKOUT_URL_INVALID");
  });
});

describe("Mollie allocation-gated QR snapshots", () => {
  const common = {
    paymentEmailJobs: 1,
    paidEvents: 1,
    paidAudits: 1,
    refundEvents: 0,
    refundAudits: 0,
    mismatchEvents: 0,
    manualReviewAudits: 0,
  };

  it("proves paid without a hard allocation has no QR", () => {
    expect(() => assertPaidSnapshot({
      ...common,
      paymentStatus: "paid",
      reconciliationIssue: null,
      paidPayments: 1,
      hardAllocations: 0,
      readyLines: 0,
      activeQr: 0,
      allQr: 0,
      qrBusinessEligible: false,
      qrUsable: false,
    })).not.toThrow();

    expect(() => assertPaidSnapshot({
      ...common,
      paymentStatus: "paid",
      reconciliationIssue: null,
      paidPayments: 1,
      hardAllocations: 0,
      readyLines: 0,
      activeQr: 1,
      allQr: 1,
      qrBusinessEligible: false,
      qrUsable: false,
    })).toThrow();
  });

  it("accepts QR readiness only after one concrete hard allocation", () => {
    expect(() => assertReadinessSnapshot({
      paymentStatus: "paid",
      allocatedLines: 1,
      allocatedQuantity: 1,
      hardAllocations: 1,
      readyLines: 1,
      activeQr: 1,
      allQr: 1,
      qrBusinessEligible: true,
      qrUsable: true,
      transactionRolledBack: true,
    })).not.toThrow();
    expect(() => assertReadinessSnapshot({
      paymentStatus: "paid",
      allocatedLines: 0,
      allocatedQuantity: 0,
      hardAllocations: 0,
      readyLines: 0,
      activeQr: 1,
      allQr: 1,
      qrBusinessEligible: false,
      qrUsable: false,
      transactionRolledBack: true,
    })).toThrow();
  });

  it("keeps mismatch and refund snapshots free of active QR access", () => {
    expect(() => assertMismatchSnapshot({
      ...common,
      paymentStatus: "pending",
      paidPayments: 0,
      hardAllocations: 0,
      readyLines: 0,
      activeQr: 0,
      allQr: 0,
      paymentEmailJobs: 0,
      reconciliationIssue: "MISMATCH_METADATA",
      mismatchEvents: 1,
      manualReviewAudits: 1,
      qrBusinessEligible: false,
      qrUsable: false,
    })).not.toThrow();
    expect(() => assertRefundSnapshot({
      ...common,
      paymentStatus: "refunded",
      paidPayments: 0,
      hardAllocations: 0,
      readyLines: 0,
      activeQr: 0,
      allQr: 0,
      reconciliationIssue: null,
      qrBusinessEligible: false,
      qrUsable: false,
      refundEvents: 1,
      refundAudits: 1,
    })).not.toThrow();
  });
});

describe("Mollie staging acceptance provider and webhook behavior", () => {
  it("accepts only a terminal full refund as release evidence", () => {
    const expectedAmount = "1.00";
    expect(isTerminalFullRefund({
      status: "pending",
      amount: { currency: "EUR", value: expectedAmount },
    }, expectedAmount)).toBe(false);
    expect(isTerminalFullRefund({
      status: "processing",
      amount: { currency: "EUR", value: expectedAmount },
    }, expectedAmount)).toBe(false);
    expect(isTerminalFullRefund({
      status: "refunded",
      amount: { currency: "EUR", value: expectedAmount },
    }, expectedAmount)).toBe(true);
    expect(isTerminalFullRefund({
      status: "refunded",
      amount: { currency: "EUR", value: "0.50" },
    }, expectedAmount)).toBe(false);
  });

  it("returns a redacted provider error without reflecting credentials or response bodies", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(new Response("secret provider detail", { status: 500 }));
    await expect(providerRequest(
      { apiKey: validEnv.MOLLIE_API_KEY },
      "/v2/profiles/me",
      {},
      fetchImpl,
    )).rejects.toThrow("MOLLIE_ACCEPTANCE_PROVIDER_HTTP_500");
  });

  it("returns only an allowlisted Supabase error code for parent RPC failures", async () => {
    const fetchImpl = vi.fn().mockResolvedValue(new Response(JSON.stringify({
      code: "23503",
      message: "secret fixture detail",
    }), { status: 409 }));
    await expect(stagingParentRpc({
      projectRef: STAGING_SUPABASE_PROJECT_REF,
      serviceRoleKey: validEnv.SUPABASE_SERVICE_ROLE_KEY,
    }, "create_parent_session", {}, fetchImpl)).rejects.toThrow(
      "MOLLIE_ACCEPTANCE_PARENT_RPC_CREATE_PARENT_SESSION_HTTP_409_23503",
    );
  });

  it("does not allow staging fixture RPC names through the hosted parent contract", async () => {
    await expect(stagingParentRpc({
      projectRef: STAGING_SUPABASE_PROJECT_REF,
      serviceRoleKey: validEnv.SUPABASE_SERVICE_ROLE_KEY,
    }, "prepare_mollie_acceptance_fixture", {}, vi.fn())).rejects.toThrow(
      "MOLLIE_ACCEPTANCE_PARENT_RPC_INVALID",
    );
  });

  it("posts the same classic form webhook three times concurrently", async () => {
    const fetchImpl = vi.fn().mockImplementation(async () => new Response(JSON.stringify({ received: true }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    }));
    await postConcurrentReplays({ appBaseUrl: validEnv.APP_BASE_URL }, "tr_Acceptance123", fetchImpl);
    expect(fetchImpl).toHaveBeenCalledTimes(3);
    for (const [, init] of fetchImpl.mock.calls) {
      expect(init).toMatchObject({ method: "POST", body: "id=tr_Acceptance123" });
      expect(init.headers["Content-Type"]).toBe("application/x-www-form-urlencoded");
    }
  });

  it("selects only the explicit paid state on the hosted test screen", async () => {
    const check = vi.fn();
    const click = vi.fn();
    const locator = (visible: boolean, actions: Record<string, unknown> = {}) => ({
      count: vi.fn().mockResolvedValue(visible ? 1 : 0),
      first: vi.fn().mockReturnValue({ isVisible: vi.fn().mockResolvedValue(visible), ...actions }),
    });
    const page = {
      getByRole: vi.fn((role: string) => role === "radio"
        ? locator(true, { check })
        : locator(true, { click })),
      locator: vi.fn(() => ({ count: vi.fn().mockResolvedValue(0) })),
    };

    await choosePaidOnHostedTestPage(page);
    expect(check).toHaveBeenCalledOnce();
    expect(click).toHaveBeenCalledOnce();
  });

  it("selects iDEAL and a test bank before choosing paid on the current hosted screen", async () => {
    let methodSelected = false;
    let issuerSelected = false;
    const methodClick = vi.fn().mockImplementation(async () => { methodSelected = true; });
    const issuerClick = vi.fn().mockImplementation(async () => { issuerSelected = true; });
    const paidCheck = vi.fn();
    const submitClick = vi.fn();
    const locator = (isVisible: () => boolean, actions: Record<string, unknown> = {}) => ({
      count: vi.fn().mockImplementation(async () => isVisible() ? 1 : 0),
      first: vi.fn().mockReturnValue({ isVisible: vi.fn().mockImplementation(async () => isVisible()), ...actions }),
    });
    const hidden = locator(() => false);
    const page = {
      getByRole: vi.fn((role: string, options: { name?: RegExp }) => {
        const name = options.name?.source ?? "";
        if (role === "radio") return locator(() => issuerSelected, { check: paidCheck });
        if (role === "button" && name.includes("iDEAL")) return locator(() => !methodSelected, { click: methodClick });
        if (role === "button" && name.includes("ABN AMRO")) return locator(() => methodSelected && !issuerSelected, { click: issuerClick });
        if (role === "button" && name.includes("continue")) return locator(() => issuerSelected, { click: submitClick });
        return hidden;
      }),
      getByText: vi.fn(() => hidden),
      locator: vi.fn(() => ({ count: vi.fn().mockResolvedValue(0) })),
      waitForTimeout: vi.fn().mockResolvedValue(undefined),
    };

    await choosePaidOnHostedTestPage(page);
    expect(methodClick).toHaveBeenCalledOnce();
    expect(issuerClick).toHaveBeenCalledOnce();
    expect(paidCheck).toHaveBeenCalledOnce();
    expect(submitClick).toHaveBeenCalledOnce();
  });

  it("selects refunded and submits the hosted test state change", async () => {
    let initialSubmitted = false;
    const initialCheck = vi.fn();
    const finalCheck = vi.fn();
    const initialClick = vi.fn().mockImplementation(async () => { initialSubmitted = true; });
    const finalClick = vi.fn();
    const locator = (visible: boolean, actions: Record<string, unknown> = {}) => ({
      count: vi.fn().mockResolvedValue(visible ? 1 : 0),
      first: vi.fn().mockReturnValue({ isVisible: vi.fn().mockResolvedValue(visible), ...actions }),
    });
    const hidden = locator(false);
    const page = {
      getByRole: vi.fn((role: string, options: { name?: RegExp }) => {
        if (role === "radio" && !initialSubmitted && options.name?.test("Volledige terugbetaling aanmaken")) {
          return locator(true, { check: initialCheck });
        }
        if (role === "radio" && initialSubmitted && options.name?.test("Terugbetaald")) {
          return locator(true, { check: finalCheck });
        }
        if (role === "button" && options.name?.test("Ga verder")) {
          return locator(true, { click: initialSubmitted ? finalClick : initialClick });
        }
        return hidden;
      }),
      locator: vi.fn(() => ({ count: vi.fn().mockResolvedValue(0) })),
      waitForTimeout: vi.fn().mockResolvedValue(undefined),
    };

    await chooseRefundedOnHostedTestPage(page);
    expect(initialCheck).toHaveBeenCalledOnce();
    expect(initialClick).toHaveBeenCalledOnce();
    expect(finalCheck).toHaveBeenCalledOnce();
    expect(finalClick).toHaveBeenCalledOnce();
  });
});
