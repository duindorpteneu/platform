import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  requireStaffRole: vi.fn(),
  serverClient: vi.fn(),
  rpc: vi.fn(),
}));
vi.mock("@/server/auth/staff", () => ({ requireStaffRole: mocks.requireStaffRole }));
vi.mock("@/server/supabase/server", () => ({ getSupabaseServerClient: mocks.serverClient }));

import { POST } from "./route";

const runId = "10000000-0000-4000-8000-000000000001";
const batchId = "20000000-0000-4000-8000-000000000001";
const requestId = "30000000-0000-4000-8000-000000000001";

function request(options?: {
  body?: unknown;
  origin?: string;
  csrf?: string;
}) {
  return new Request("https://tenue.example/api/imports/commits", {
    method: "POST",
    headers: {
      origin: options?.origin ?? "https://tenue.example",
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": options?.csrf ?? "same-origin",
      "content-type": "application/json",
    },
    body: JSON.stringify(options?.body ?? {
        runId,
        planHash: "a".repeat(64),
        clientRequestId: requestId,
        confirmed: true,
      }),
  });
}

describe("POST /api/imports/commits", () => {
  beforeEach(() => {
    process.env.APP_BASE_URL = "https://tenue.example";
    process.env.DYNAMIC_IMPORT_ENABLED = "true";
    process.env.IMPORT_STAGING_ENCRYPTION_KEY = Buffer.alloc(32, 1).toString("base64url");
    mocks.requireStaffRole.mockReset().mockResolvedValue({ role: "beheerder" });
    mocks.rpc.mockReset();
    mocks.serverClient.mockReset().mockResolvedValue({
      schema: () => ({ rpc: mocks.rpc }),
    });
  });

  it("queueert alleen het exact bevestigde immutable plan", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: { runId, batchId, status: "commit_queued", reused: false },
      error: null,
    });
    const response = await POST(request());
    expect(response.status).toBe(202);
    expect(mocks.rpc).toHaveBeenCalledWith(
      "authorize_dynamic_import_commit",
      expect.objectContaining({
        p_run_id: runId,
        p_plan_hash: "a".repeat(64),
        p_client_request_id: requestId,
        p_request_hash: expect.stringMatching(/^[0-9a-f]{64}$/),
      }),
    );
  });

  it("weigert een commit wanneer het getoonde plan intussen is gewijzigd", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "40001", message: "DYNAMIC_IMPORT_PLAN_CHANGED" },
    });
    const response = await POST(request());
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({
      error: expect.stringContaining("gewijzigd"),
    });
  });

  it("weigert een ongeldige of niet-expliciet bevestigde body vóór autorisatie", async () => {
    const response = await POST(request({
      body: {
        runId,
        planHash: "a".repeat(64),
        clientRequestId: requestId,
        confirmed: false,
      },
    }));
    expect(response.status).toBe(400);
    expect(mocks.requireStaffRole).not.toHaveBeenCalled();
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("weigert cross-site commits vóór parsing of databasegebruik", async () => {
    const response = await POST(request({
      origin: "https://aanvaller.example",
    }));
    expect(response.status).toBe(403);
    expect(mocks.requireStaffRole).not.toHaveBeenCalled();
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("vereist een beheerder met MFA", async () => {
    mocks.requireStaffRole.mockRejectedValueOnce(
      new Error("STAFF_AUTHORIZATION_REQUIRED"),
    );
    const response = await POST(request());
    expect(response.status).toBe(403);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("stopt fail-closed wanneer runtime-importverwerking is gepauzeerd", async () => {
    process.env.DYNAMIC_IMPORT_ENABLED = "false";
    const response = await POST(request());
    expect(response.status).toBe(503);
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("meldt een verlopen dry-run zonder bestaaninformatie te lekken", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "55000", message: "DYNAMIC_IMPORT_DRY_RUN_EXPIRED" },
    });
    const response = await POST(request());
    expect(response.status).toBe(410);
    expect(await response.json()).toEqual({
      error: "Deze dry-run is verlopen. Upload het bestand opnieuw.",
    });
  });

  it("hergebruikt exact dezelfde al afgeronde commit idempotent", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: { runId, batchId, status: "committed", reused: true },
      error: null,
    });
    const response = await POST(request());
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      status: "committed",
      reused: true,
    });
  });

  it("redigeert onverwachte databasefouten tot een stabiele fout", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "XX000", message: "interne databasegegevens" },
    });
    const response = await POST(request());
    expect(response.status).toBe(500);
    expect(JSON.stringify(await response.json())).not.toContain("databasegegevens");
  });
});
