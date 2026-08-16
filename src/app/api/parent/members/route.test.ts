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
  buildQrFragmentUrl: vi.fn(),
  deriveQrLocator: mocks.deriveQr,
}));

import { GET } from "./route";

const memberId = "10000000-0000-4000-8000-000000000001";
const memberSeasonId = "20000000-0000-4000-8000-000000000001";
const seasonId = "30000000-0000-4000-8000-000000000001";
const orderId = "40000000-0000-4000-8000-000000000001";
const secondMemberId = "60000000-0000-4000-8000-000000000001";
const secondMemberSeasonId = "70000000-0000-4000-8000-000000000001";

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
        qrKeyVersion: 1,
        qrNonce: "n".repeat(43),
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
      "get_parent_package_workspace_v6",
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

  it("behoudt meerdere expliciet gekoppelde kinderen in één oudersessie", async () => {
    const input = workspace();
    input.members.push({
      ...input.members[0],
      memberId: secondMemberId,
      memberSeasonId: secondMemberSeasonId,
      firstName: "Sem",
      relationNumber: "REL-2",
      order: {
        ...input.members[0].order,
        id: "80000000-0000-4000-8000-000000000001",
      },
    });
    mocks.rpc.mockResolvedValueOnce({ data: input, error: null });
    const response = await GET();
    expect(response.status).toBe(200);
    const body = await response.json();
    expect(body.members).toHaveLength(2);
    expect(body.members.map((member: { memberSeasonId: string }) => member.memberSeasonId)).toEqual([
      memberSeasonId,
      secondMemberSeasonId,
    ]);
  });

  it("activeert geen QR voor een betaald pakket zonder afhaalklare reservering", async () => {
    const response = await GET();
    expect(response.status).toBe(200);
    expect(mocks.deriveQr).not.toHaveBeenCalled();
  });

  it("bouwt een afhaalcode uit de opgeslagen versie en random nonce zonder die velden te lekken", async () => {
    const input = workspace();
    input.members[0].order!.articleLines[0].status = "ready_for_pickup";
    mocks.rpc.mockResolvedValueOnce({ data: input, error: null });
    mocks.deriveQr.mockReturnValueOnce(
      `q2.k1.${"a".repeat(43)}`,
    );
    const response = await GET();
    expect(response.status).toBe(200);
    expect(mocks.deriveQr).toHaveBeenCalledWith({
      generation: 1,
      keyVersion: 1,
      nonce: "n".repeat(43),
      orderId,
    });
    const body = await response.json();
    expect(body.members[0].order.qrDataUrl).toMatch(
      /^data:image\/png;base64,/,
    );
    expect(body.members[0].order).not.toHaveProperty("qrNonce");
    expect(body.members[0].order).not.toHaveProperty("qrKeyVersion");
  });

  it("faalt gesloten wanneer een actieve QR-sleutelversie niet beschikbaar is", async () => {
    const input = workspace();
    input.members[0].order!.articleLines[0].status = "ready_for_pickup";
    mocks.rpc.mockResolvedValueOnce({ data: input, error: null });
    mocks.deriveQr.mockImplementationOnce(() => {
      throw new Error("QR_TOKEN_KEY_VERSION_UNAVAILABLE");
    });
    const response = await GET();
    expect(response.status).toBe(503);
    expect(JSON.stringify(await response.json())).not.toContain(
      "QR_TOKEN",
    );
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
