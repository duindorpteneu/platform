import { describe, expect, it, vi } from "vitest";
import { isOperationalFeatureEnabled, type FeatureFlagClient } from "@/server/operations/feature-flags";

function client(result: { data: Record<string, unknown> | null; error: unknown }) {
  const maybeSingle = vi.fn().mockResolvedValue(result);
  return {
    schema: vi.fn().mockReturnValue({
      from: vi.fn().mockReturnValue({
        select: vi.fn().mockReturnValue({ eq: vi.fn().mockReturnValue({ maybeSingle }) }),
      }),
    }),
  } as unknown as FeatureFlagClient;
}

describe("operational feature flags", () => {
  it("enables only an explicit true database switch", async () => {
    await expect(isOperationalFeatureEnabled(client({ data: { mollie_enabled: true }, error: null }), "mollie_enabled")).resolves.toBe(true);
    await expect(isOperationalFeatureEnabled(client({ data: { mollie_enabled: false }, error: null }), "mollie_enabled")).resolves.toBe(false);
  });
  it("fails closed on missing data and database errors", async () => {
    await expect(isOperationalFeatureEnabled(client({ data: null, error: null }), "email_enabled")).resolves.toBe(false);
    await expect(isOperationalFeatureEnabled(client({ data: { email_enabled: true }, error: { code: "db" } }), "email_enabled")).resolves.toBe(false);
  });
});
