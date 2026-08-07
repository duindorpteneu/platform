import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const source = readFileSync(
  new URL("./test-capacity.mjs", import.meta.url),
  "utf8",
);

describe("capacity acceptance architecture", () => {
  it("requires a disposable local database and the complete canon capacity", () => {
    expect(source).toContain('CAPACITY_TEST_DISPOSABLE_DB !== "1"');
    expect(source).toContain("const memberCount = 1_500");
    expect(source).toContain("const orderLineCount = 10_000");
    expect(source).toContain("const staffSessionCount = 25");
    expect(source).toContain("const criticalOrderCount = 40");
    expect(source).toContain("assertLocalDatabase(local.DB_URL)");
  });

  it("measures exchange and commit separately with a strict p95", () => {
    expect(source).toContain("Math.ceil(sorted.length * 0.95) - 1");
    expect(source).toContain('assertLatency("QR-exchange"');
    expect(source).toContain('assertLatency("Fulfilmentcommit"');
    expect(source).toContain("p95 >= latencyLimitMs");
  });

  it("captures process logs without echoing sensitive runtime values", () => {
    expect(source).toContain('stdio: ["ignore", "pipe", "pipe"]');
    expect(source).toContain("LOG_PRIVACY_RUNTIME_SENTINEL_FOUND");
    expect(source).toContain(
      "sensitiveValues.some((value) => appLogs.includes(value))",
    );
    expect(source).not.toContain("process.stderr.write(appLogs");
    expect(source).not.toContain("process.stdout.write(appLogs");
  });
});
