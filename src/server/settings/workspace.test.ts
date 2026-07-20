import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  requireRole: vi.fn(),
  serverClient: vi.fn(),
  rpc: vi.fn(),
  logError: vi.fn(),
}));

vi.mock("next/cache", () => ({ unstable_noStore: vi.fn() }));
vi.mock("@/server/auth/staff", () => ({ requireStaffRole: mocks.requireRole }));
vi.mock("@/server/supabase/server", () => ({ getSupabaseServerClient: mocks.serverClient }));
vi.mock("@/server/security/logger", () => ({ operationalLogger: { error: mocks.logError } }));

import { getSettingsWorkspace } from "./workspace";

describe("settings workspace diagnostics", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.requireRole.mockResolvedValue({ role: "beheerder" });
    mocks.serverClient.mockResolvedValue({ schema: () => ({ rpc: mocks.rpc }) });
  });

  it.each(["PGRST106", "PGRST202"])("classifies %s as a stale hosted schema contract", async (code) => {
    mocks.rpc.mockResolvedValue({ data: null, error: { code } });
    await expect(getSettingsWorkspace()).rejects.toThrow("SETTINGS_SCHEMA_CONTRACT_STALE");
    expect(mocks.logError).toHaveBeenCalledWith("settings.workspace_load_failed", {
      code: code.toLowerCase(),
      provider: "supabase",
      route: "/backoffice/instellingen",
    });
  });

  it("keeps authorization failures distinct", async () => {
    mocks.rpc.mockResolvedValue({ data: null, error: { code: "42501" } });
    await expect(getSettingsWorkspace()).rejects.toThrow("STAFF_AUTHORIZATION_REQUIRED");
  });
});
