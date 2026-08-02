import { randomBytes } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import {
  assertImportStagingKey,
  stagingKeyFingerprint,
} from "./check-import-staging-key.mjs";

function environment(key = "") {
  return {
    NEXT_PUBLIC_SUPABASE_URL: "https://project-ref.supabase.co",
    SUPABASE_SERVICE_ROLE_KEY: "service-role-test-value",
    IMPORT_STAGING_ENCRYPTION_KEY: key,
  };
}

describe("importstaging deployment key gate", () => {
  it("stuurt alleen de niet-geheime fingerprint naar de service-only RPC", async () => {
    const key = randomBytes(32).toString("base64url");
    const fetcher = vi.fn(async (_url, init) => {
      expect(init.headers).toMatchObject({
        "Content-Profile": "app",
        apikey: "service-role-test-value",
      });
      expect(JSON.parse(String(init.body))).toEqual({
        p_key_fingerprint: stagingKeyFingerprint(key),
      });
      expect(String(init.body)).not.toContain(key);
      return new Response(JSON.stringify({ compatible: true, pending: 2 }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    });
    await expect(assertImportStagingKey(environment(key), fetcher))
      .resolves.toEqual({ compatible: true, pending: 2 });
  });

  it("ondersteunt een lege key uitsluitend wanneer de database nul actieve uploads bevestigt", async () => {
    const fetcher = vi.fn(async (_url, init) => {
      expect(JSON.parse(String(init.body))).toEqual({ p_key_fingerprint: null });
      return new Response(JSON.stringify({ compatible: true, pending: 0 }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    });
    await expect(assertImportStagingKey(environment(), fetcher))
      .resolves.toEqual({ compatible: true, pending: 0 });
  });

  it("blokkeert rotatie zonder remote foutdetails of secretwaarden terug te geven", async () => {
    const key = randomBytes(32).toString("base64url");
    const fetcher = vi.fn(async () => new Response(JSON.stringify({
      code: "55000",
      message: "IMPORT_STAGING_KEY_ROTATION_BLOCKED",
      details: key,
    }), {
      status: 500,
      headers: { "content-type": "application/json" },
    }));
    await expect(assertImportStagingKey(environment(key), fetcher))
      .rejects.toThrow("IMPORT_STAGING_KEY_ROTATION_BLOCKED");
  });

  it("weigert niet-canonieke keys lokaal vóór de netwerkcall", async () => {
    const fetcher = vi.fn();
    await expect(assertImportStagingKey(environment("A".repeat(44)), fetcher))
      .rejects.toThrow("IMPORT_STAGING_ENCRYPTION_KEY_INVALID");
    expect(fetcher).not.toHaveBeenCalled();
  });
});
