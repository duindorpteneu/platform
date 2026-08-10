import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ publish: vi.fn() }));
vi.mock("@/server/packages/workspace", () => ({ publishPackageRevision: mocks.publish }));
vi.mock("@/server/security/route-guard", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/server/security/route-guard")>(),
  guardBrowserMutation: () => null,
}));

import { POST } from "./route";

const templateId = "93000000-0000-4000-8000-000000000001";
const revisionId = "94000000-0000-4000-8000-000000000001";
const contentHash = "a".repeat(64);

function request(body: unknown) {
  return new Request("https://tenue.example/api/packages/publish", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" },
    body: JSON.stringify(body),
  });
}

describe("POST /api/packages/publish", () => {
  beforeEach(() => {
    mocks.publish.mockReset().mockResolvedValue({
      data: { templateId, revisionId, revisionNumber: 1, active: true, default: true, contentHash },
      error: null,
    });
  });

  it("publiceert met expliciete defaultkeuze en stale-writebescherming", async () => {
    const response = await POST(request({ revisionId, makeDefault: true, expectedHash: contentHash }));
    expect(response.status).toBe(200);
    expect(mocks.publish).toHaveBeenCalledWith(revisionId, true, contentHash, null);
  });

  it("vertaalt een stale revision naar 409", async () => {
    mocks.publish.mockResolvedValueOnce({ data: null, error: { code: "40001", message: "PACKAGE_REVISION_STALE" } });
    const response = await POST(request({ revisionId, makeDefault: false, expectedHash: contentHash }));
    expect(response.status).toBe(409);
    expect(await response.json()).toMatchObject({ error: expect.stringContaining("intussen gewijzigd") });
  });
});
