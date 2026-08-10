import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  requireStaffRole: vi.fn(),
  serverClient: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock("@/server/auth/staff", () => ({ requireStaffRole: mocks.requireStaffRole }));
vi.mock("@/server/supabase/server", () => ({ getSupabaseServerClient: mocks.serverClient }));

import { POST } from "./route";

function uploadRequest(body: string) {
  return new Request("https://tenue.example/api/imports/commit", {
    method: "POST",
    headers: {
      origin: "https://tenue.example",
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
      "content-type": "text/csv",
      "x-duindorp-file-name": encodeURIComponent("leden.csv"),
    },
    body,
  });
}

describe("POST /api/imports/commit", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    process.env.DYNAMIC_IMPORT_ENABLED = "false";
    mocks.requireStaffRole.mockReset().mockResolvedValue({ userId: "staff" });
    mocks.rpc.mockReset().mockResolvedValue({
      data: { batchId: "10000000-0000-4000-8000-000000000001", upserted: 1 },
      error: null,
    });
    mocks.serverClient.mockReset().mockResolvedValue({
      schema: () => ({ rpc: mocks.rpc }),
    });
  });

  it("behoudt de begrensde legacycompatibiliteit zolang v2 uit staat", async () => {
    const response = await POST(uploadRequest([
      "Relatienummer;Voornaam;Achternaam;E-mailadres;Team",
      "DSV-1;Noa;Jansen;noa@example.invalid;JO13-1",
    ].join("\n")));
    expect(response.status).toBe(201);
    expect(mocks.rpc).toHaveBeenCalledWith(
      "commit_sportlink_import",
      expect.objectContaining({ p_checksum: expect.stringMatching(/^[0-9a-f]{64}$/) }),
    );
  });

  it("sluit de legacycommit vóór bodyverwerking bij v2-cutover", async () => {
    process.env.DYNAMIC_IMPORT_ENABLED = "true";
    process.env.IMPORT_STAGING_ENCRYPTION_KEY = Buffer.alloc(32, 4).toString("base64url");
    const response = await POST(uploadRequest("A,B\n1,2"));
    expect(response.status).toBe(410);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.requireStaffRole).not.toHaveBeenCalled();
    expect(mocks.rpc).not.toHaveBeenCalled();
  });
});
