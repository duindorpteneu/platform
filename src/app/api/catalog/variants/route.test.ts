import { beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  requireRole: vi.fn(),
  client: vi.fn(),
  rpc: vi.fn(),
}));

vi.mock("@/server/auth/staff", () => ({ requireStaffRole: mocks.requireRole }));
vi.mock("@/server/supabase/server", () => ({ getSupabaseServerClient: mocks.client }));
vi.mock("@/server/security/route-guard", async (importOriginal) => ({
  ...await importOriginal<typeof import("@/server/security/route-guard")>(),
  guardBrowserMutation: () => null,
}));

import { POST } from "./route";

const articleId = "72000000-0000-4000-8000-000000000001";
const variantId = "73000000-0000-4000-8000-000000000001";

function request(body: unknown) {
  return new Request("https://tenue.example/api/catalog/variants", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Duindorp-CSRF": "same-origin",
    },
    body: JSON.stringify(body),
  });
}

describe("POST /api/catalog/variants", () => {
  beforeEach(() => {
    mocks.requireRole.mockReset().mockResolvedValue({ role: "beheerder" });
    mocks.rpc.mockReset().mockResolvedValue({ data: variantId, error: null });
    mocks.client.mockReset().mockResolvedValue({
      schema: () => ({ rpc: mocks.rpc }),
    });
  });

  it("stuurt expliciete maatalias(sen) naar het transactionele v2-contract", async () => {
    const response = await POST(request({
      articleId,
      variantId: null,
      size: "XXL",
      supplierCode: "2XL",
      aliases: ["Extra Extra Large", "XX-Large"],
      active: true,
      sortOrder: 20,
    }));

    expect(response.status).toBe(201);
    expect(mocks.rpc).toHaveBeenCalledWith("upsert_catalog_variant_v2", {
      p_article_id: articleId,
      p_variant_id: null,
      p_size: "XXL",
      p_supplier_code: "2XL",
      p_aliases: ["Extra Extra Large", "XX-Large"],
      p_active: true,
      p_sort_order: 20,
    });
  });

  it("negeert redundante aliassen van het eigen maatlabel en de eigen code", async () => {
    const response = await POST(request({
      articleId,
      variantId: null,
      size: "116",
      supplierCode: "M-116",
      aliases: ["１１６", "m-116", "Jeugd 116"],
      active: true,
      sortOrder: 10,
    }));

    expect(response.status).toBe(201);
    expect(mocks.rpc).toHaveBeenCalledWith("upsert_catalog_variant_v2", {
      p_article_id: articleId,
      p_variant_id: null,
      p_size: "116",
      p_supplier_code: "M-116",
      p_aliases: ["Jeugd 116"],
      p_active: true,
      p_sort_order: 10,
    });
  });

  it("weigert genormaliseerd dubbele aliassen en Anders vóór de database", async () => {
    for (const aliases of [[" 2xl ", "２ＸＬ"], ["Anders…"], ["XXL\u061C"], ["XX\u00ADL"]]) {
      const response = await POST(request({
        articleId,
        variantId: null,
        size: "XXL",
        supplierCode: null,
        aliases,
        active: true,
        sortOrder: 20,
      }));
      expect(response.status).toBe(400);
    }
    expect(mocks.rpc).not.toHaveBeenCalled();
  });

  it("vertaalt een databaseconflict zonder interne details te lekken", async () => {
    mocks.rpc.mockResolvedValueOnce({
      data: null,
      error: { code: "23505", message: "VARIANT_MATCH_KEY_EXISTS sensitive" },
    });
    const response = await POST(request({
      articleId,
      variantId,
      size: "XXL",
      supplierCode: null,
      aliases: [],
      active: true,
      sortOrder: 20,
    }));

    expect(response.status).toBe(409);
    expect(await response.json()).toEqual({
      error: "Deze maat, code of alias bestaat al voor het artikel.",
    });
  });
});
