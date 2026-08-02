import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  requireStaffRole: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock("@/server/auth/staff", () => ({
  requireStaffRole: mocks.requireStaffRole,
}));
vi.mock("@/server/qr/tokens", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/server/qr/tokens")>(),
  hashQrBearerToken: () => "a".repeat(64),
}));
vi.mock("@/server/supabase/server", () => ({
  getSupabaseServerClient: async () => ({
    schema: () => ({ rpc: mocks.rpc }),
  }),
}));
vi.mock("@/server/security/route-guard", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/server/security/route-guard")>(),
  guardBrowserMutation: () => null,
}));

import { POST } from "./route";

const found = {
  status: "found",
  orderId: "10000000-0000-4000-8000-000000000001",
  paid: true,
  member: {
    name: "Noa Tester",
    team: "JO13-1",
    relationNumberSuffix: null,
  },
  lines: [{
    id: "20000000-0000-4000-8000-000000000001",
    article: "Shirt",
    size: "152",
    status: "ready_for_pickup",
  }],
};

function request() {
  return new Request("https://tenue.example/api/fulfilment/lookup", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Duindorp-CSRF": "same-origin",
    },
    body: JSON.stringify({ token: `v1.${"a".repeat(43)}` }),
  });
}

describe("POST /api/fulfilment/lookup", () => {
  beforeEach(() => {
    mocks.requireStaffRole.mockReset().mockResolvedValue({ role: "uitgifte" });
    mocks.rpc.mockReset().mockResolvedValue({ data: found, error: null });
  });

  it("returns a valid minimal member without a relation number", async () => {
    const response = await POST(request());
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(found);
  });

  it("fails closed when the database response adds DOB", async () => {
    mocks.rpc.mockResolvedValue({
      data: {
        ...found,
        member: { ...found.member, dateOfBirth: "2012-03-04" },
      },
      error: null,
    });
    const response = await POST(request());
    expect(response.status).toBe(500);
    expect(JSON.stringify(await response.json())).not.toContain("2012");
  });
});
