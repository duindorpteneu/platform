import { randomBytes } from "node:crypto";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { IMPORT_POLICY } from "@/lib/import-contract";

const mocks = vi.hoisted(() => ({
  requireStaffRole: vi.fn(),
  serverClient: vi.fn(),
  rpc: vi.fn(),
  readPayload: vi.fn(),
  openStagedCsv: vi.fn(),
  assertHeaders: vi.fn(),
  diagnostics: vi.fn(),
  selected: vi.fn(),
  headerHash: vi.fn(),
}));

vi.mock("@/server/auth/staff", () => ({ requireStaffRole: mocks.requireStaffRole }));
vi.mock("@/server/supabase/server", () => ({ getSupabaseServerClient: mocks.serverClient }));
vi.mock("@/server/imports/workspace", () => ({ readStagedImportPayload: mocks.readPayload }));
vi.mock("@/server/imports/mapping", () => ({
  openStagedCsv: mocks.openStagedCsv,
  assertMappingHeaders: mocks.assertHeaders,
  buildSizeDiagnostics: mocks.diagnostics,
  selectedMappingForStorage: mocks.selected,
  importHeaderHash: mocks.headerHash,
}));

import { GET, POST } from "./route";

const batchId = "10000000-0000-4000-8000-000000000001";
const actorId = "20000000-0000-4000-8000-000000000001";
const seasonId = "30000000-0000-4000-8000-000000000001";
const catalogHash = "a".repeat(64);
const workspace = {
  batchId,
  seasonId,
  revision: 0,
  catalogHash,
  articles: [],
  presets: [],
};

function request(body: unknown) {
  return new Request("https://tenue.example/api/imports/mapping", {
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

describe("/api/imports/mapping", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    process.env.DYNAMIC_IMPORT_ENABLED = "true";
    process.env.IMPORT_STAGING_ENCRYPTION_KEY = randomBytes(32).toString("base64url");
    mocks.requireStaffRole.mockReset().mockResolvedValue({
      userId: actorId,
      role: "beheerder",
      activeSeason: { id: seasonId, name: "2026/2027" },
    });
    mocks.rpc.mockReset();
    mocks.serverClient.mockReset().mockResolvedValue({ schema: () => ({ rpc: mocks.rpc }) });
    mocks.readPayload.mockReset().mockResolvedValue({ batchId });
    mocks.openStagedCsv.mockReset().mockReturnValue({
      headers: ["Voornaam"],
      delimiter: ";",
      records: [["Noa"]],
      rowShapeIssues: [],
    });
    mocks.assertHeaders.mockReset();
    mocks.diagnostics.mockReset().mockReturnValue([]);
    mocks.selected.mockReset().mockReturnValue([{
      columnIndex: 0,
      sourceHeaderHash: "b".repeat(64),
      target: { kind: "member_field", field: "first_name" },
    }]);
    mocks.headerHash.mockReset().mockReturnValue("c".repeat(64));
  });

  it("levert alleen de actor- en seizoensgebonden mappingworkspace zonder cache", async () => {
    mocks.rpc.mockResolvedValueOnce({ data: workspace, error: null });
    const response = await GET(new Request(
      `https://tenue.example/api/imports/mapping?batchId=${batchId}`,
    ));
    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(await response.json()).toEqual(workspace);
    expect(mocks.rpc).toHaveBeenCalledWith(
      "get_dynamic_import_mapping_workspace",
      { p_batch_id: batchId },
    );
  });

  it("bindt decryptie aan actor, seizoen en revisie en bewaart geen headertekst", async () => {
    mocks.rpc
      .mockResolvedValueOnce({ data: workspace, error: null })
      .mockResolvedValueOnce({
        data: {
          batchId,
          revision: 1,
          mappingHash: "d".repeat(64),
          catalogHash,
          reused: false,
        },
        error: null,
      });
    const response = await POST(request({
      batchId,
      expectedRevision: 0,
      expectedCatalogHash: catalogHash,
      preset: null,
      mapping: {
        policy: IMPORT_POLICY,
        entries: [{
          columnIndex: 0,
          sourceHeader: "Voornaam",
          target: { kind: "member_field", field: "first_name" },
        }],
      },
    }));
    expect(response.status).toBe(201);
    expect(response.headers.get("cache-control")).toContain("no-store");
    expect(mocks.readPayload).toHaveBeenCalledWith({
      batchId,
      actorId,
      seasonId,
      previewRevision: 0,
    });
    const saveParameters = mocks.rpc.mock.calls[1]?.[1];
    expect(saveParameters.p_mapping).toEqual(mocks.selected.mock.results[0]?.value);
    expect(JSON.stringify(saveParameters.p_mapping)).not.toContain("Voornaam");
  });

  it("weigert catalogusdrift voordat ciphertext wordt gelezen", async () => {
    mocks.rpc.mockResolvedValueOnce({ data: { ...workspace, revision: 1 }, error: null });
    const response = await POST(request({
      batchId,
      expectedRevision: 0,
      expectedCatalogHash: catalogHash,
      mapping: {
        policy: IMPORT_POLICY,
        entries: [{
          columnIndex: 0,
          sourceHeader: "Voornaam",
          target: { kind: "member_field", field: "first_name" },
        }],
      },
    }));
    expect(response.status).toBe(409);
    expect(mocks.readPayload).not.toHaveBeenCalled();
  });

  it("weigert een niet-beheerder en een te grote chunked JSON-body", async () => {
    mocks.requireStaffRole.mockRejectedValueOnce(new Error("STAFF_AUTHORIZATION_REQUIRED"));
    expect((await GET(new Request(
      `https://tenue.example/api/imports/mapping?batchId=${batchId}`,
    ))).status).toBe(403);

    const oversized = new Request("https://tenue.example/api/imports/mapping", {
      method: "POST",
      headers: {
        origin: "https://tenue.example",
        host: "tenue.example",
        "sec-fetch-site": "same-origin",
        "x-duindorp-csrf": "same-origin",
        "content-type": "application/json",
        "content-length": "1",
      },
      body: new ReadableStream<Uint8Array>({
        start(controller) {
          controller.enqueue(new Uint8Array(64 * 1024 + 1));
          controller.close();
        },
      }),
      duplex: "half",
    } as RequestInit & { duplex: "half" });
    expect((await POST(oversized)).status).toBe(413);
  });
});
