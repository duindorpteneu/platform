import { describe, expect, it } from "vitest";
import { createOperationalLogger } from "./logger";

describe("redacted operational logger", () => {
  it("emits one structured line with only allowlisted, validated fields", () => {
    const lines: string[] = [];
    const logger = createOperationalLogger({
      now: () => new Date("2026-07-18T12:00:00.000Z"),
      write: (line) => lines.push(line),
    });

    logger.warn("payment.reconciliation_mismatch", {
      correlationId: "550E8400-E29B-41D4-A716-446655440000",
      provider: "mollie",
      route: "/api/webhooks/mollie",
      status: 409,
      count: 1,
      durationMs: 32,
    });

    expect(JSON.parse(lines[0]!)).toEqual({
      timestamp: "2026-07-18T12:00:00.000Z",
      level: "warn",
      event: "payment.reconciliation_mismatch",
      correlationId: "550e8400-e29b-41d4-a716-446655440000",
      count: 1,
      durationMs: 32,
      provider: "mollie",
      route: "/api/webhooks/mollie",
      status: 409,
    });
  });

  it("drops unknown, free-text, secret and PII fields", () => {
    const lines: string[] = [];
    const logger = createOperationalLogger({ write: (line) => lines.push(line) });
    logger.error("email.delivery_failed", {
      email: "ouder@example.test",
      error: "Provider rejected token SG.secret",
      name: "Persoonsnaam",
      token: "secret-token",
      webhookBody: { email: "ouder@example.test" },
      code: "provider_rejected",
    });

    const serialized = lines[0]!;
    expect(serialized).not.toContain("ouder@example.test");
    expect(serialized).not.toContain("Persoonsnaam");
    expect(serialized).not.toContain("secret-token");
    expect(serialized).not.toContain("SG.secret");
    expect(JSON.parse(serialized)).toMatchObject({ event: "email.delivery_failed", code: "provider_rejected" });
  });

  it.each(["user@example.test", "payment failed for member", "../unsafe", ""])('rejects unsafe event identifier "%s"', (event) => {
    const logger = createOperationalLogger({ write: () => undefined });
    expect(() => logger.info(event)).toThrow(TypeError);
  });

  it("drops malformed allowlisted values instead of serializing them", () => {
    const lines: string[] = [];
    const logger = createOperationalLogger({ write: (line) => lines.push(line) });
    logger.info("request.completed", {
      correlationId: "not-a-uuid",
      provider: "evil" as "mollie",
      route: "/api/orders?email=ouder@example.test",
      status: 999,
      count: -1,
      durationMs: Number.NaN,
    });
    expect(JSON.parse(lines[0]!)).toMatchObject({ level: "info", event: "request.completed" });
    expect(Object.keys(JSON.parse(lines[0]!))).toEqual(["timestamp", "level", "event"]);
  });
});
