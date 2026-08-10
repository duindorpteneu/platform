import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ clone: vi.fn() }));
vi.mock("@/server/packages/workspace", () => ({ clonePackageRevision: mocks.clone }));
vi.mock("@/server/security/route-guard", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/server/security/route-guard")>(),
  guardBrowserMutation: () => null,
}));

import { POST } from "./route";

const templateId = "93000000-0000-4000-8000-000000000001";
const sourceRevisionId = "94000000-0000-4000-8000-000000000001";
const revisionId = "94000000-0000-4000-8000-000000000002";
const contentHash = "a".repeat(64);

function request(body: unknown) {
  return new Request("https://tenue.example/api/packages/revision", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" },
    body: JSON.stringify(body),
  });
}

describe("POST /api/packages/revision", () => {
  beforeEach(() => {
    mocks.clone.mockReset().mockResolvedValue({
      data: { templateId, revisionId, revisionNumber: 2, itemCount: 1, contentHash },
      error: null,
    });
  });

  it("bindt de clone aan bronrevisie en inhoudshash", async () => {
    const response = await POST(request({ templateId, sourceRevisionId, expectedHash: contentHash }));
    expect(response.status).toBe(201);
    expect(mocks.clone).toHaveBeenCalledWith(templateId, sourceRevisionId, contentHash, null);
  });

  it("vertaalt een bestaand concept naar een conflict", async () => {
    mocks.clone.mockResolvedValueOnce({ data: null, error: { code: "23505", message: "PACKAGE_DRAFT_ALREADY_EXISTS" } });
    const response = await POST(request({ templateId, sourceRevisionId, expectedHash: contentHash }));
    expect(response.status).toBe(409);
  });
});
