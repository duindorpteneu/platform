import { describe, expect, it } from "vitest";
import { CORRELATION_ID_HEADER, normalizeCorrelationId, resolveCorrelationId, withCorrelationId } from "./correlation";

describe("correlation ids", () => {
  it.each([
    ["550e8400-e29b-41d4-a716-446655440000", "550e8400-e29b-41d4-a716-446655440000"],
    [" 550E8400-E29B-41D4-A716-446655440000 ", "550e8400-e29b-41d4-a716-446655440000"],
    ["not-a-uuid", null],
    ["550e8400-e29b-01d4-a716-446655440000", null],
    [null, null],
  ])("normalizes only RFC UUID values", (input, expected) => {
    expect(normalizeCorrelationId(input)).toBe(expected);
  });

  it("generates a fresh UUID when the incoming value is untrusted", () => {
    const resolved = resolveCorrelationId("member@example.test");
    expect(normalizeCorrelationId(resolved)).toBe(resolved);
    expect(resolved).not.toContain("example");
  });

  it("copies the id without mutating the incoming headers", () => {
    const original = new Headers({ accept: "application/json" });
    const result = withCorrelationId(original, "550e8400-e29b-41d4-a716-446655440000");

    expect(original.has(CORRELATION_ID_HEADER)).toBe(false);
    expect(result.get(CORRELATION_ID_HEADER)).toBe("550e8400-e29b-41d4-a716-446655440000");
  });
});
