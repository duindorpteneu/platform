import { describe, expect, it, vi } from "vitest";
// @ts-expect-error The production acceptance entrypoint intentionally uses plain Node.js ESM.
import * as acceptance from "./mollie-staging-acceptance.mjs";

const {
  ACCEPTANCE_CONFIRMATION,
  STAGING_SUPABASE_PROJECT_REF,
  choosePaidOnHostedTestPage,
  createFixtureIdentity,
  createPsqlRunner,
  postConcurrentReplays,
  providerRequest,
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
  });

  it("preserves the complete database URI through process environment instead of command arguments", () => {
    const spawnImpl = vi.fn().mockReturnValue({ status: 0, stdout: "{}\n" });
    const databaseUrl = `${validEnv.SUPABASE_DB_URL}&application_name=mollie-acceptance`;
    const psql = createPsqlRunner(databaseUrl, spawnImpl);
    psql({ sql: "select '{}'::json;" });

    const [, args, options] = spawnImpl.mock.calls[0];
    expect(args.join(" ")).not.toContain("secret");
    expect(args.join(" ")).not.toContain("supabase.co");
    expect(options.env).toMatchObject({
      PGDATABASE: databaseUrl,
      PGCONNECT_TIMEOUT: "15",
    });
    expect(options.env).not.toHaveProperty("PGHOST");
    expect(options.env).not.toHaveProperty("PGUSER");
    expect(options.env).not.toHaveProperty("PGPASSWORD");
    expect(options.env).not.toHaveProperty("PGSSLMODE");
  });

  it("creates deterministic, fictitious and run-isolated fixture identities", () => {
    const first = createFixtureIdentity(validEnv.MOLLIE_ACCEPTANCE_RUN_ID);
    expect(createFixtureIdentity(validEnv.MOLLIE_ACCEPTANCE_RUN_ID)).toEqual(first);
    expect(createFixtureIdentity("123456789-2")).not.toEqual(first);
    expect(first.fixtureEmail).toMatch(/@example\.invalid$/);
    expect(first.paidOrderId).toMatch(/^[0-9a-f-]{36}$/);
  });

  it("rejects non-Mollie and insecure checkout URLs", () => {
    expect(validateCheckoutUrl("https://www.mollie.com/checkout/test")).toBe("https://www.mollie.com/checkout/test");
    expect(() => validateCheckoutUrl("https://mollie.com.evil.invalid/checkout")).toThrow("MOLLIE_ACCEPTANCE_CHECKOUT_URL_INVALID");
    expect(() => validateCheckoutUrl("http://www.mollie.com/checkout")).toThrow("MOLLIE_ACCEPTANCE_CHECKOUT_URL_INVALID");
  });
});

describe("Mollie staging acceptance provider and webhook behavior", () => {
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
});
