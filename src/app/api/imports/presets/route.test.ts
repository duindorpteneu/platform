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

const presetId = "10000000-0000-4000-8000-000000000001";

function request(body: unknown) {
  return new Request("https://tenue.example/api/imports/presets", {
    method: "POST",
    headers: {
      origin: "https://tenue.example",
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

describe("POST /api/imports/presets", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    process.env.DYNAMIC_IMPORT_ENABLED = "true";
    process.env.IMPORT_STAGING_ENCRYPTION_KEY = randomBytes(32).toString("base64url");
    mocks.requireStaffRole.mockReset().mockResolvedValue({ role: "beheerder" });
    mocks.rpc.mockReset();
    mocks.serverClient.mockReset().mockResolvedValue({ schema: () => ({ rpc: mocks.rpc }) });
  });

  it("normaliseert bronheaders en slaat uitsluitend mappingmetadata op", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: {
        id: presetId,
        name: "Sportlink standaard",
        revision: 1,
        entries: [{
          sourceHeaderKey: "maat broek",
          target: {
            kind: "product_size",
            articleId: "20000000-0000-4000-8000-000000000001",
          },
        }],
      },
      error: null,
    });
    const response = await POST(request({
      action: "save",
      name: "Sportlink standaard",
      entries: [{
        sourceHeaderKey: " Maat\u00a0Broek ",
        target: {
          kind: "product_size",
          articleId: "20000000-0000-4000-8000-000000000001",
        },
      }],
    }));
    expect(response.status).toBe(201);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.rpc.mock.calls[0]?.[1].p_entries).toEqual([{
      sourceHeaderKey: "maat broek",
      target: {
        kind: "product_size",
        articleId: "20000000-0000-4000-8000-000000000001",
      },
    }]);
  });

  it("archiveert met optimistic concurrency en maakt geen hard delete", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: { id: presetId, revision: 3, archived: true },
      error: null,
    });
    const response = await POST(request({
      action: "archive",
      presetId,
      expectedRevision: 2,
    }));
    expect(response.status).toBe(200);
    expect(mocks.rpc).toHaveBeenCalledWith(
      "archive_dynamic_import_mapping_preset",
      expect.objectContaining({
        p_preset_id: presetId,
        p_expected_revision: 2,
      }),
    );
  });

  it("weigert dubbele headers, niet-beheerder en een uitgeschakelde runtime", async () => {
    const duplicate = await POST(request({
      action: "save",
      name: "Dubbel",
      entries: [
        { sourceHeaderKey: "E-mail", target: { kind: "member_field", field: "email" } },
        { sourceHeaderKey: " e-mail ", target: { kind: "member_field", field: "first_name" } },
      ],
    }));
    expect(duplicate.status).toBe(422);
    expect(mocks.rpc).not.toHaveBeenCalled();

    mocks.requireStaffRole.mockRejectedValueOnce(new Error("STAFF_AUTHORIZATION_REQUIRED"));
    expect((await POST(request({
      action: "archive",
      presetId,
      expectedRevision: 1,
    }))).status).toBe(403);

    process.env.DYNAMIC_IMPORT_ENABLED = "false";
    expect((await POST(request({
      action: "archive",
      presetId,
      expectedRevision: 1,
    }))).status).toBe(503);
  });
});
