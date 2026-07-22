import { describe, expect, it, vi } from "vitest";
// @ts-expect-error The production acceptance entrypoint intentionally uses plain Node.js ESM.
import * as acceptance from "./mollie-staging-acceptance.mjs";

const {
  ACCEPTANCE_CONFIRMATION,
  STAGING_SUPABASE_PROJECT_REF,
  choosePaidOnHostedTestPage,
  createFixtureIdentity,
  postConcurrentReplays,
  providerRequest,
  stagingParentRpc,
  validateCheckoutUrl,
  validateConfiguration,
  validateTargetConfiguration,
  waitForStagingParentMembers,
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

  it("waits until both parent members are visible through the hosted app schema", async () => {
    const identity = createFixtureIdentity(validEnv.MOLLIE_ACCEPTANCE_RUN_ID);
    const fetchImpl = vi.fn()
      .mockResolvedValueOnce(new Response("false", { status: 200 }))
      .mockResolvedValueOnce(new Response("true", { status: 200 }));
    const sleep = vi.fn().mockResolvedValue(undefined);

    await waitForStagingParentMembers({
      projectRef: STAGING_SUPABASE_PROJECT_REF,
      serviceRoleKey: validEnv.SUPABASE_SERVICE_ROLE_KEY,
    }, identity, { fetchImpl, sleep });

    expect(fetchImpl).toHaveBeenCalledTimes(2);
    expect(fetchImpl.mock.calls[0][0]).toContain("/rest/v1/rpc/parent_otp_members_visible");
    expect(JSON.parse(fetchImpl.mock.calls[0][1].body)).toEqual({
      p_member_ids: [identity.paidMemberId, identity.mismatchMemberId],
      p_email: identity.fixtureEmail,
    });
    expect(sleep).toHaveBeenCalledWith(2_000);
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

  it("selects iDEAL before choosing paid on the current two-step test screen", async () => {
    let methodSelected = false;
    const methodClick = vi.fn().mockImplementation(async () => { methodSelected = true; });
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
        if (role === "radio") return locator(() => methodSelected, { check: paidCheck });
        if (role === "button" && name.includes("iDEAL")) return locator(() => !methodSelected, { click: methodClick });
        if (role === "button" && name.includes("continue")) return locator(() => methodSelected, { click: submitClick });
        return hidden;
      }),
      getByText: vi.fn(() => hidden),
      locator: vi.fn(() => ({ count: vi.fn().mockResolvedValue(0) })),
      waitForTimeout: vi.fn().mockResolvedValue(undefined),
    };

    await choosePaidOnHostedTestPage(page);
    expect(methodClick).toHaveBeenCalledOnce();
    expect(paidCheck).toHaveBeenCalledOnce();
    expect(submitClick).toHaveBeenCalledOnce();
  });
});
