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
  return new Request("https://tenue.example/api/imports/preview", {
    method: "POST",
    headers: {
      origin: "https://tenue.example",
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
      "content-type": "text/csv",
      "x-duindorp-file-name": encodeURIComponent("leden.csv"),
      ...headers,
    },
    body,
    duplex: "half",
  } as RequestInit & { duplex: "half" });
}

describe("POST /api/imports/preview", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    process.env.DYNAMIC_IMPORT_ENABLED = "false";
    mocks.requireStaffRole.mockReset().mockResolvedValue({ userId: "staff" });
    mocks.rpc.mockReset().mockResolvedValue({
      data: { new: 1, updated: 0, unchanged: 0 },
      error: null,
    });
    mocks.serverClient.mockReset().mockResolvedValue({ schema: () => ({ rpc: mocks.rpc }) });
  });

  it("accepteert de begrensde raw-CSV upload met expliciete bestandsmetadata", async () => {
    const csv = [
      "Relatienummer;Voornaam;Achternaam;E-mailadres;Team",
      "DSV-1;Noa;Jansen;noa@example.invalid;JO13-1",
    ].join("\n");

    const response = await POST(uploadRequest(csv));

    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      summary: { total: 1, valid: 1, invalid: 0, new: 1 },
    });
    expect(mocks.rpc).toHaveBeenCalledWith("get_sportlink_import_summary", {
      p_members: [expect.objectContaining({ relation_number: "DSV-1" })],
    });
  });

  it("weigert een chunked upload zodra de echte bytes de limiet overschrijden", async () => {
    const response = await POST(uploadRequest(new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new Uint8Array(10 * 1_024 * 1_024 + 1));
        controller.close();
      },
    }), { "content-length": "1" }));

    expect(response.status).toBe(413);
    expect(mocks.requireStaffRole).toHaveBeenCalledTimes(1);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("weigert gecomprimeerde of niet-CSV uploads vóór verwerking", async () => {
    const response = await POST(uploadRequest("x", {
      "content-encoding": "gzip",
    }));

    expect(response.status).toBe(415);
    expect(mocks.requireStaffRole).not.toHaveBeenCalled();
  });

  it("sluit de legacyroute vóór bodyverwerking bij v2-cutover", async () => {
    process.env.DYNAMIC_IMPORT_ENABLED = "true";
    process.env.IMPORT_STAGING_ENCRYPTION_KEY = Buffer.alloc(32, 3).toString("base64url");
    const response = await POST(uploadRequest("A,B\n1,2"));
    expect(response.status).toBe(410);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.requireStaffRole).not.toHaveBeenCalled();
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
});
