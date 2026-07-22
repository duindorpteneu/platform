import { describe, expect, it, vi } from "vitest";
import { isOperationalFeatureEnabled, type FeatureFlagClient } from "@/server/operations/feature-flags";

function client(result: { data: unknown; error: unknown }) {
  return { rpc: vi.fn().mockResolvedValue(result) } as FeatureFlagClient;
}

describe("operational feature flags", () => {
  it("enables only an explicit true database switch", async () => {
    const enabled = client({ data: true, error: null });
    await expect(isOperationalFeatureEnabled(enabled, "mollie_enabled")).resolves.toBe(true);
    expect(enabled.rpc).toHaveBeenCalledWith("is_operational_feature_enabled", { p_flag: "mollie_enabled" });
    await expect(isOperationalFeatureEnabled(client({ data: false, error: null }), "mollie_enabled")).resolves.toBe(false);
  });
  it("fails closed on missing data and database errors", async () => {
    await expect(isOperationalFeatureEnabled(client({ data: null, error: null }), "email_enabled")).resolves.toBe(false);
    await expect(isOperationalFeatureEnabled(client({ data: true, error: { code: "db" } }), "email_enabled")).resolves.toBe(false);
  });
});
