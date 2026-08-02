import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ save: vi.fn() }));
vi.mock("@/server/packages/workspace", () => ({ savePackageDraft: mocks.save }));
vi.mock("@/server/security/route-guard", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/server/security/route-guard")>(),
  guardBrowserMutation: () => null,
}));

import { POST } from "./route";

const seasonId = "91000000-0000-4000-8000-000000000001";
const articleId = "92000000-0000-4000-8000-000000000001";
const templateId = "93000000-0000-4000-8000-000000000001";
const revisionId = "94000000-0000-4000-8000-000000000001";
const contentHash = "a".repeat(64);

function request(body: unknown) {
  return new Request("https://tenue.example/api/packages/draft", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Duindorp-CSRF": "same-origin" },
    body: JSON.stringify(body),
  });
}

describe("POST /api/packages/draft", () => {
  beforeEach(() => {
    mocks.save.mockReset().mockResolvedValue({
      data: { templateId, revisionId, created: true, itemCount: 1, contentHash },
      error: null,
    });
  });

  it("stuurt uitsluitend het strikte centen- en productcontract door", async () => {
    const body = {
      templateId: null,
      revisionId: null,
      seasonId,
      key: "speler",
      name: "Speler",
      description: "",
      priceCents: 12_500,
      items: [{ articleId, quantity: 1, sortOrder: 10 }],
      expectedHash: null,
    };
    const response = await POST(request(body));
    expect(response.status).toBe(201);
    expect(mocks.save).toHaveBeenCalledWith(body, null);
  });

  it("weigert dubbele producten vóór de database", async () => {
    const item = { articleId, quantity: 1, sortOrder: 10 };
    const response = await POST(request({
      templateId: null,
      revisionId: null,
      seasonId,
      key: "speler",
      name: "Speler",
      description: "",
      priceCents: 12_500,
      items: [item, item],
      expectedHash: null,
    }));
    expect(response.status).toBe(400);
    expect(mocks.save).not.toHaveBeenCalled();
  });
});
