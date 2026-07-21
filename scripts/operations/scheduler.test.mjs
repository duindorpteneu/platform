import { describe, expect, it } from "vitest";
import { invokeInternal, shouldRunRetention, validateSchedulerConfig } from "./scheduler.mjs";

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

  it("runs retention once per Amsterdam calendar day after 03:17", () => {
    const firstStart = shouldRunRetention(new Date("2026-07-21T01:16:00Z"), "");
    const before = shouldRunRetention(new Date("2026-07-21T01:16:00Z"), "2026-07-20");
    const due = shouldRunRetention(new Date("2026-07-21T01:17:00Z"), "2026-07-20");
    expect(firstStart.due).toBe(true);
    expect(before.due).toBe(false);
    expect(due.due).toBe(true);
    expect(shouldRunRetention(new Date("2026-07-21T10:00:00Z"), due.date).due).toBe(false);
  });
});
