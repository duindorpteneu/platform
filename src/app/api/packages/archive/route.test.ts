import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ archive: vi.fn() }));
vi.mock("@/server/packages/workspace", () => ({ archivePackageRevision: mocks.archive }));
vi.mock("@/server/security/route-guard", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/server/security/route-guard")>(),
  guardBrowserMutation: () => null,
}));

import { POST } from "./route";

const templateId = "93000000-0000-4000-8000-000000000001";
const revisionId = "94000000-0000-4000-8000-000000000001";
const contentHash = "a".repeat(64);

function request(body: unknown) {
  return new Request("https://tenue.example/api/packages/archive", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" },
    body: JSON.stringify(body),
  });
}

describe("POST /api/packages/archive", () => {
  beforeEach(() => {
    mocks.archive.mockReset().mockResolvedValue({
      data: { templateId, revisionId, archived: true, contentHash },
      error: null,
    });
  });

  it("vereist en bewaart een gecontroleerde reden", async () => {
    const response = await POST(request({ revisionId, reason: "Niet langer aangeboden", expectedHash: contentHash }));
    expect(response.status).toBe(200);
    expect(mocks.archive).toHaveBeenCalledWith(revisionId, "Niet langer aangeboden", contentHash, null);
  });

  it("weigert een lege reden vóór de database", async () => {
    const response = await POST(request({ revisionId, reason: "", expectedHash: contentHash }));
    expect(response.status).toBe(400);
    expect(mocks.archive).not.toHaveBeenCalled();
  });
});
