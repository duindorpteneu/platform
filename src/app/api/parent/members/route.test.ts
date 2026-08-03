import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  getParentSession: vi.fn(),
  getAdmin: vi.fn(),
  rpc: vi.fn(),
  deriveQr: vi.fn(),
}));
vi.mock("@/server/auth/parent-session", () => ({
  getParentSession: mocks.getParentSession,
}));
vi.mock("@/server/supabase/admin", () => ({
  getSupabaseAdminClient: mocks.getAdmin,
}));
vi.mock("@/server/qr/tokens", () => ({
  deriveQrBearerToken: mocks.deriveQr,
}));

import { GET } from "./route";

const memberId = "10000000-0000-4000-8000-000000000001";
const memberSeasonId = "20000000-0000-4000-8000-000000000001";
const seasonId = "30000000-0000-4000-8000-000000000001";
const orderId = "40000000-0000-4000-8000-000000000001";

function workspace() {
  return {
    enabled: true,
    members: [{
      memberId,
      memberSeasonId,
      relationNumber: "REL-1",
      firstName: "Noa",
      insertion: null,
      lastName: "Duin",
      team: "JO13-1",
      dateOfBirth: "2013-05-17",
      gender: "female",
      seasonId,
      seasonName: "2026/2027",
      availablePackages: [],
      revision: "a".repeat(64),
      order: {
        id: orderId,
        amountDueCents: 12500,
        paymentStatus: "paid",
        orderStatus: "Nalevering",
        qrVersion: 1,
        packageRevisionId: null,
        packageName: null,
        packageDescription: null,
        packagePriceCents: null,
        currency: null,
        revisionLabel: null,
        legacy: true,
        canSwitchPackage: false,
        sizesConfirmed: true,
        revision: "a".repeat(64),
        articleLines: [{
          id: "50000000-0000-4000-8000-000000000001",
          article: "Shirt",
          size: "152",
          quantity: 1,
          status: "backorder",
        }],
        items: [],
      },
    }],
  };
}

describe("GET /api/parent/members", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    mocks.getParentSession.mockReset().mockResolvedValue({
      tokenHash: "b".repeat(64),
    });
    mocks.rpc.mockReset().mockResolvedValue({
      data: workspace(),
      error: null,
    });
    mocks.getAdmin.mockReset().mockReturnValue({ rpc: mocks.rpc });
    mocks.deriveQr.mockReset();
  });

  it("retourneert uitsluitend het strikt gevalideerde lid-seizoenpakket inclusief DOB", async () => {
    const response = await GET();
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.rpc).toHaveBeenCalledWith(
      "get_parent_package_workspace_v3",
      { p_token_hash: "b".repeat(64) },
    );
    expect(await response.json()).toMatchObject({
      enabled: true,
      members: [{
        memberSeasonId,
        dateOfBirth: "2013-05-17",
        order: { qrDataUrl: null },
      }],
    });
  });

  it("activeert geen QR voor een betaald pakket zonder afhaalklare reservering", async () => {
    const response = await GET();
    expect(response.status).toBe(200);
    expect(mocks.deriveQr).not.toHaveBeenCalled();
  });

  it("weigert een uitgebreid databaseantwoord zodat extra PII niet stil uitlekt", async () => {
    const input = workspace();
    Object.assign(input.members[0], {
      email: "niet-doorsturen@example.invalid",
    });
    mocks.rpc.mockResolvedValueOnce({ data: input, error: null });
    const response = await GET();
    expect(response.status).toBe(502);
    expect(JSON.stringify(await response.json())).not.toContain(
      "niet-doorsturen",
    );
  });

  it("vereist een geldige oudersessie", async () => {
    mocks.getParentSession.mockResolvedValueOnce(null);
    const response = await GET();
    expect(response.status).toBe(401);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
});
