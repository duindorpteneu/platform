import { describe, expect, it } from "vitest";
import { parseServerEnv } from "@/lib/env";

describe("server provider configuration", () => {
  it("allows both external providers to remain safely disabled", () => {
    const env = parseServerEnv({ APP_BASE_URL: "http://localhost:3100" });
    expect(env.MOLLIE_ENABLED).toBe("false");
    expect(env.EMAIL_ENABLED).toBe("false");
    expect(env.DYNAMIC_IMPORT_ENABLED).toBe("false");
    expect(env.IMPORT_RAW_RETENTION_HOURS).toBe(24);
  });

  it("treats explicitly empty optional provider values as unset while disabled", () => {
    const env = parseServerEnv({
      APP_BASE_URL: "https://staging-duindorp.dgwebservices.nl",
      MOLLIE_ENABLED: "false",
      MOLLIE_API_KEY: "",
      EMAIL_ENABLED: "false",
      SENDGRID_API_KEY: "",
      SENDGRID_FROM_NAME: "",
      SENDGRID_FROM_EMAIL: "",
      SENDGRID_REPLY_TO_EMAIL: "   ",
      SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY: "",
    });
    expect(env.MOLLIE_API_KEY).toBeUndefined();
    expect(env.SENDGRID_API_KEY).toBeUndefined();
    expect(env.SENDGRID_FROM_NAME).toBeUndefined();
    expect(env.SENDGRID_FROM_EMAIL).toBeUndefined();
    expect(env.SENDGRID_REPLY_TO_EMAIL).toBeUndefined();
    expect(env.SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY).toBeUndefined();
  });

  it("fails closed when Mollie is enabled without HTTPS and credentials", () => {
    expect(() => parseServerEnv({ MOLLIE_ENABLED: "true", APP_BASE_URL: "http://localhost:3100" })).toThrow();
  });

  it("vereist een canonieke aparte importstaging-sleutel bij activatie", () => {
    expect(() => parseServerEnv({
      DYNAMIC_IMPORT_ENABLED: "true",
      IMPORT_STAGING_ENCRYPTION_KEY: "",
    })).toThrow();
    expect(() => parseServerEnv({
      DYNAMIC_IMPORT_ENABLED: "true",
      IMPORT_STAGING_ENCRYPTION_KEY: Buffer.alloc(32).toString("base64"),
    })).toThrow();
    expect(parseServerEnv({
      DYNAMIC_IMPORT_ENABLED: "true",
      IMPORT_STAGING_ENCRYPTION_KEY: Buffer.alloc(32, 7).toString("base64url"),
      IMPORT_RAW_RETENTION_HOURS: "72",
    })).toMatchObject({
      DYNAMIC_IMPORT_ENABLED: "true",
      IMPORT_RAW_RETENTION_HOURS: 72,
    });
    expect(() => parseServerEnv({ IMPORT_RAW_RETENTION_HOURS: "73" })).toThrow();
  });

  it("valideert een huidige en optionele vorige QR-sleutel als één keyring", () => {
    const current = Buffer.alloc(32, 4).toString("base64url");
    const previous = Buffer.alloc(32, 3).toString("base64url");
    expect(parseServerEnv({
      QR_TOKEN_PEPPER: current,
      QR_TOKEN_PEPPER_VERSION: "2",
      QR_TOKEN_PREVIOUS_PEPPER: previous,
      QR_TOKEN_PREVIOUS_PEPPER_VERSION: "1",
    })).toMatchObject({
      QR_TOKEN_PEPPER: current,
      QR_TOKEN_PEPPER_VERSION: 2,
      QR_TOKEN_PREVIOUS_PEPPER: previous,
      QR_TOKEN_PREVIOUS_PEPPER_VERSION: 1,
    });
    expect(() => parseServerEnv({
      QR_TOKEN_PEPPER: current,
      QR_TOKEN_PEPPER_VERSION: "2",
      QR_TOKEN_PREVIOUS_PEPPER: previous,
    })).toThrow();
    expect(() => parseServerEnv({
      QR_TOKEN_PEPPER: current,
      QR_TOKEN_PEPPER_VERSION: "2",
      QR_TOKEN_PREVIOUS_PEPPER: previous,
      QR_TOKEN_PREVIOUS_PEPPER_VERSION: "2",
    })).toThrow();
    expect(() => parseServerEnv({
      QR_TOKEN_PEPPER: "x".repeat(43),
    })).toThrow();
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
      SENDGRID_FROM_NAME: "Kledingcommissie Duindorp SV",
      SENDGRID_FROM_EMAIL: "tenue@duindorp.example",
      SENDGRID_REPLY_TO_EMAIL: "commissie@duindorp.example",
      SENDGRID_EVENT_WEBHOOK_PUBLIC_KEY: "public-key",
      CRON_SECRET: "x".repeat(16),
    })).toThrow();
  });
});
