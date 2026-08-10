import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ recover: vi.fn() }));
vi.mock("@/lib/env", () => ({ getServerEnv: () => ({ APP_BASE_URL: "https://tenue.example" }) }));
vi.mock("@/server/security/route-guard", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/server/security/route-guard")>(),
  guardBrowserMutation: () => null,
}));
vi.mock("@/server/email/recovery", () => ({ recoverEmailJob: mocks.recover }));

import { POST } from "./route";

const jobId = "71000000-0000-4000-8000-000000000001";
const updatedAt = "2026-07-21T10:00:00.000Z";

function request(body: unknown) {
  return new Request(`https://tenue.example/api/email/jobs/${jobId}/recovery`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Correlation-ID": "72000000-0000-4000-8000-000000000001" },
    body: JSON.stringify(body),
  });
}

describe("POST /api/email/jobs/[jobId]/recovery", () => {
  beforeEach(() => {
    mocks.recover.mockReset().mockResolvedValue({
      data: { jobId, status: "sent", attempts: 1, updatedAt: "2026-07-21T10:10:00.000Z" },
      error: null,
    });
  });

  it("requires provider acceptance evidence before confirming sent", async () => {
    const response = await POST(request({
      expectedUpdatedAt: updatedAt,
      resolution: "confirm_sent",
      reason: "provider_confirmed_accepted",
      providerEvidenceRef: "ticket/SG-12345",
      providerMessageId: "sg-message-123",
      attestedNotAccepted: false,
    }), { params: Promise.resolve({ jobId }) });
    expect(response.status).toBe(200);
    expect(mocks.recover).toHaveBeenCalledWith(jobId, expect.objectContaining({ resolution: "confirm_sent" }), "72000000-0000-4000-8000-000000000001");
  });

  it("rejects retry without explicit non-acceptance attestation", async () => {
    const response = await POST(request({
      expectedUpdatedAt: updatedAt,
      resolution: "retry_proven_not_accepted",
      reason: "provider_confirmed_not_accepted",
      providerEvidenceRef: "ticket/SG-12345",
      providerMessageId: null,
      attestedNotAccepted: false,
    }), { params: Promise.resolve({ jobId }) });
    expect(response.status).toBe(400);
    expect(mocks.recover).not.toHaveBeenCalled();
  });

  it("maps an optimistic concurrency conflict to reloadable HTTP 409", async () => {
    mocks.recover.mockResolvedValueOnce({ data: null, error: { code: "40001" } });
    const response = await POST(request({
      expectedUpdatedAt: updatedAt,
      resolution: "confirm_sent",
      reason: "provider_confirmed_accepted",
      providerEvidenceRef: "ticket/SG-12345",
      providerMessageId: "sg-message-123",
      attestedNotAccepted: false,
    }), { params: Promise.resolve({ jobId }) });
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: expect.stringContaining("intussen gewijzigd") });
  });
});
