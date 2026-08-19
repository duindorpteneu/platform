import { describe, expect, it } from "vitest";
import {
  invokeInternal,
  runSchedulerCycle,
  shouldRunRetention,
  validateSchedulerConfig,
} from "./scheduler.mjs";

const base = {
  APP_ENVIRONMENT: "staging",
  CRON_SECRET: "c".repeat(32),
  EMAIL_ENABLED: "false",
};

describe("operations scheduler", () => {
  it("requires an independent production heartbeat", () => {
    expect(() => validateSchedulerConfig({ ...base, APP_ENVIRONMENT: "production" })).toThrow("SCHEDULER_HEARTBEAT_REQUIRED");
    expect(validateSchedulerConfig({ ...base, APP_ENVIRONMENT: "production", OPERATIONS_HEARTBEAT_URL: "https://monitor.example/secret" }).heartbeatUrl).toContain("monitor.example");
  });

  it("rejects public and credential-bearing targets", () => {
    expect(() => validateSchedulerConfig({ ...base, OPERATIONS_INTERNAL_BASE_URL: "https://duindorp.dgwebservices.nl" })).toThrow("SCHEDULER_INTERNAL_TARGET_INVALID");
    expect(() => validateSchedulerConfig({ ...base, OPERATIONS_HEARTBEAT_URL: "https://user:pass@monitor.example/ping" })).toThrow("SCHEDULER_HEARTBEAT_INVALID");
  });

  it("accepts paused email only when email is disabled", async () => {
    const config = validateSchedulerConfig(base);
    await expect(invokeInternal(config, "/api/internal/jobs/email", "POST", async () => ({ status: "paused" }))).resolves.toEqual({ status: "paused" });
    await expect(invokeInternal({ ...config, emailEnabled: true }, "/api/internal/jobs/email", "POST", async () => ({ status: "paused" }))).rejects.toThrow("EMAIL_UNEXPECTEDLY_PAUSED");
  });

  it("valideert het importworkercontract tegen de runtimepoort", async () => {
    const disabled = validateSchedulerConfig({
      ...base,
      DYNAMIC_IMPORT_ENABLED: "false",
    });
    const enabled = validateSchedulerConfig({
      ...base,
      DYNAMIC_IMPORT_ENABLED: "true",
    });
    await expect(invokeInternal(
      disabled,
      "/api/internal/jobs/imports",
      "POST",
      async () => ({ status: "paused" }),
    )).resolves.toEqual({ status: "paused" });
    await expect(invokeInternal(
      enabled,
      "/api/internal/jobs/imports",
      "POST",
      async () => ({ status: "paused" }),
    )).rejects.toThrow("IMPORT_UNEXPECTEDLY_PAUSED");
    await expect(invokeInternal(
      enabled,
      "/api/internal/jobs/imports",
      "POST",
      async () => ({ status: "unknown" }),
    )).rejects.toThrow("IMPORT_RESPONSE_INVALID");
    for (const status of ["idle", "processing", "previewed", "committed"]) {
      await expect(invokeInternal(
        enabled,
        "/api/internal/jobs/imports",
        "POST",
        async () => ({ status }),
      )).resolves.toEqual({ status });
    }
  });

  it("runs de idempotente retentie uiterlijk iedere vijf minuten", () => {
    const firstStart = shouldRunRetention(new Date("2026-07-21T01:16:00Z"), "");
    const before = shouldRunRetention(new Date("2026-07-21T01:20:59Z"), "2026-07-21T01:16:00.000Z");
    const due = shouldRunRetention(new Date("2026-07-21T01:21:00Z"), "2026-07-21T01:16:00.000Z");
    expect(firstStart.due).toBe(true);
    expect(before.due).toBe(false);
    expect(due.due).toBe(true);
    expect(shouldRunRetention(new Date("2026-07-21T01:21:01Z"), due.timestamp).due).toBe(false);
  });

  it("voert retentie ook uit wanneer de e-mailjob faalt", async () => {
    const calls = [];
    const originalFetch = globalThis.fetch;
    globalThis.fetch = async (url) => {
      calls.push(String(url));
      if (String(url).endsWith("/email")) throw new Error("EMAIL_PROVIDER_DOWN");
      if (String(url).endsWith("/imports")) {
        return new Response(JSON.stringify({ status: "paused" }), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      }
      if (String(url).endsWith("/inventory")) {
        return new Response(JSON.stringify({ status: "paused" }), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      }
      if (String(url).endsWith("/retention")) {
        return new Response(JSON.stringify({ status: "completed" }), {
          status: 200,
          headers: { "content-type": "application/json" },
        });
      }
      throw new Error("UNEXPECTED_REQUEST");
    };
    try {
      const config = validateSchedulerConfig(base);
      const state = { lastRetentionAt: "" };
      await expect(
        runSchedulerCycle(config, state, new Date("2026-08-02T20:00:00Z")),
      ).rejects.toThrow("EMAIL_JOB_EMAIL_PROVIDER_DOWN");
      expect(calls).toEqual([
        "http://app:3000/api/internal/jobs/email",
        "http://app:3000/api/internal/jobs/imports",
        "http://app:3000/api/internal/jobs/inventory",
        "http://app:3000/api/internal/jobs/retention",
      ]);
      expect(state.lastRetentionAt).toBe("2026-08-02T20:00:00.000Z");
    } finally {
      globalThis.fetch = originalFetch;
    }
  });

  it.each(["health", "heartbeat"])(
    "ververst de containerhealthmarker niet bij een mislukte %s-check",
    async (failurePoint) => {
      const writes = [];
      const config = validateSchedulerConfig(base);
      const invoke = async (_config, path) => {
        if (failurePoint === "health" && path.endsWith("/health")) {
          throw new Error("OPERATIONS_DEGRADED");
        }
        if (
          path.endsWith("/email")
          || path.endsWith("/imports")
          || path.endsWith("/inventory")
        ) {
          return { status: "paused" };
        }
        if (path.endsWith("/retention")) return { status: "completed" };
        return { status: "healthy" };
      };
      const heartbeat = async () => {
        if (failurePoint === "heartbeat") throw new Error("HEARTBEAT_HTTP_503");
      };
      await expect(runSchedulerCycle(
        config,
        { lastRetentionAt: "" },
        new Date("2026-08-03T08:00:00Z"),
        {
          invoke,
          heartbeat,
          healthWriter: async (value) => writes.push(value),
        },
      )).rejects.toThrow();
      expect(writes).toEqual([]);
    },
  );

  it("neemt de falende interne route op in schedulerfouten", async () => {
    const config = validateSchedulerConfig(base);
    await expect(invokeInternal(
      config,
      "/api/internal/jobs/email",
      "POST",
      async () => {
        throw new Error("HTTP_503");
      },
    )).rejects.toThrow("EMAIL_JOB_HTTP_503");
    await expect(invokeInternal(
      config,
      "/api/internal/health",
      "GET",
      async () => {
        throw new Error("HTTP_503");
      },
    )).rejects.toThrow("INTERNAL_HEALTH_HTTP_503");
  });
});
