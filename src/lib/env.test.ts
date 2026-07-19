import { describe, expect, it } from "vitest";
import { parseServerEnv } from "@/lib/env";

describe("server provider configuration", () => {
  it("allows both external providers to remain safely disabled", () => {
    const env = parseServerEnv({ APP_BASE_URL: "http://localhost:3100" });
    expect(env.MOLLIE_ENABLED).toBe("false");
    expect(env.EMAIL_ENABLED).toBe("false");
  });

  it("treats explicitly empty optional provider values as unset while disabled", () => {
    const env = parseServerEnv({
      APP_BASE_URL: "https://staging-duindorp.dgwebservices.nl",
      MOLLIE_ENABLED: "false",
      MOLLIE_API_KEY: "",
      EMAIL_ENABLED: "false",
      SENDGRID_API_KEY: "",
      SENDGRID_FROM_EMAIL: "",
      SENDGRID_REPLY_TO_EMAIL: "   ",
      SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY: "",
    });
    expect(env.MOLLIE_API_KEY).toBeUndefined();
    expect(env.SENDGRID_API_KEY).toBeUndefined();
    expect(env.SENDGRID_FROM_EMAIL).toBeUndefined();
    expect(env.SENDGRID_REPLY_TO_EMAIL).toBeUndefined();
    expect(env.SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY).toBeUndefined();
  });

  it("fails closed when Mollie is enabled without HTTPS and credentials", () => {
    expect(() => parseServerEnv({ MOLLIE_ENABLED: "true", APP_BASE_URL: "http://localhost:3100" })).toThrow();
  });

  it("rejects a live Mollie key outside production", () => {
    expect(() => parseServerEnv({
      NODE_ENV: "development",
      MOLLIE_ENABLED: "true",
      MOLLIE_API_KEY: "live_secret",
      PARENT_TOKEN_PEPPER: "x".repeat(32),
      APP_BASE_URL: "https://staging.example.test",
    })).toThrow();
  });

  it("requires worker and webhook secrets when e-mail is enabled", () => {
    expect(() => parseServerEnv({ EMAIL_ENABLED: "true" })).toThrow();
  });

  it("requires HTTPS for links in enabled e-mail", () => {
    expect(() => parseServerEnv({
      EMAIL_ENABLED: "true",
      APP_BASE_URL: "http://localhost:3100",
      SENDGRID_API_KEY: "SG.test",
      SENDGRID_FROM_EMAIL: "tenue@duindorp.example",
      SENDGRID_REPLY_TO_EMAIL: "commissie@duindorp.example",
      SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY: "public-key",
      CRON_SECRET: "x".repeat(16),
    })).toThrow();
  });
});
