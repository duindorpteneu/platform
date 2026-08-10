import { randomBytes } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  requireStaffRole: vi.fn(),
  serverClient: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock("@/server/auth/staff", () => ({ requireStaffRole: mocks.requireStaffRole }));
vi.mock("@/server/supabase/server", () => ({ getSupabaseServerClient: mocks.serverClient }));

import { POST } from "./route";

function uploadRequest(body: BodyInit, headers: Record<string, string> = {}) {
  return new Request("https://tenue.example/api/imports/uploads", {
    method: "POST",
    headers: {
      origin: "https://tenue.example",
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
      "content-type": "text/csv",
      "x-duindorp-file-name": encodeURIComponent("Sportlink leden.csv"),
      "x-duindorp-idempotency-key": "10000000-0000-4000-8000-000000000001",
      ...headers,
    },
    body,
    duplex: "half",
  } as RequestInit & { duplex: "half" });
}

describe("POST /api/imports/uploads", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    process.env.DYNAMIC_IMPORT_ENABLED = "true";
    process.env.IMPORT_STAGING_ENCRYPTION_KEY = randomBytes(32).toString("base64url");
    process.env.IMPORT_RAW_RETENTION_HOURS = "24";
    mocks.requireStaffRole.mockReset().mockResolvedValue({
      userId: "20000000-0000-4000-8000-000000000001",
      role: "beheerder",
      displayName: "Beheerder",
      activeSeason: { id: "30000000-0000-4000-8000-000000000001", name: "2026/2027" },
    });
    mocks.rpc.mockReset().mockResolvedValue({
      data: {
        batchId: "40000000-0000-4000-8000-000000000001",
        status: "uploaded",
        expiresAt: "2026-08-03T20:00:00.000Z",
        reused: false,
      },
      error: null,
    });
    mocks.serverClient.mockReset().mockResolvedValue({ schema: () => ({ rpc: mocks.rpc }) });
  });

  it("stageert uitsluitend versleutelde bytes en retourneert vluchtige kolomdiagnose", async () => {
    const response = await POST(uploadRequest([
      "Relatienummer;Voornaam;Maat Broek",
      "DSV-1;Noa;152",
      "DSV-2;Mila;164",
    ].join("\n")));
    expect(response.status).toBe(201);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(await response.json()).toMatchObject({
      batchId: "40000000-0000-4000-8000-000000000001",
      diagnosis: { rowCount: 2, columnCount: 3, delimiter: ";" },
      columns: [
        expect.objectContaining({ label: "Relatienummer", uniqueValueCount: 2 }),
        expect.objectContaining({ label: "Voornaam" }),
        expect.objectContaining({ label: "Maat Broek", uniqueValues: ["152", "164"] }),
      ],
    });
    const parameters = mocks.rpc.mock.calls[0]?.[1];
    expect(parameters.p_ciphertext_base64).not.toContain("DSV-1");
    expect(parameters).not.toHaveProperty("p_headers");
    expect(parameters).not.toHaveProperty("p_rows");
    expect(parameters).toMatchObject({
      p_row_count: 2,
      p_column_count: 3,
      p_retention_hours: 24,
      p_key_fingerprint: expect.stringMatching(/^[0-9a-f]{64}$/),
    });
  });

  it("weigert kledingcommissie vóór het lezen van de upload", async () => {
    mocks.requireStaffRole.mockRejectedValueOnce(new Error("STAFF_AUTHORIZATION_REQUIRED"));
    const response = await POST(uploadRequest("A,B\n1,2"));
    expect(response.status).toBe(403);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("vereist beide featurepoorten en een geldige idempotentiesleutel", async () => {
    process.env.DYNAMIC_IMPORT_ENABLED = "false";
    expect((await POST(uploadRequest("A,B\n1,2"))).status).toBe(503);
    process.env.DYNAMIC_IMPORT_ENABLED = "true";
    expect((await POST(uploadRequest("A,B\n1,2", {
      "x-duindorp-idempotency-key": "geen-uuid",
    }))).status).toBe(400);
  });

  it("weigert duplicate headers en een chunked byte-overschrijding", async () => {
    expect((await POST(uploadRequest("Maat,ｍａａｔ\n152,164"))).status).toBe(400);
    const oversized = await POST(uploadRequest(new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new Uint8Array(10 * 1024 * 1024 + 1));
        controller.close();
      },
    }), { "content-length": "1" }));
    expect(oversized.status).toBe(413);
  });
});
