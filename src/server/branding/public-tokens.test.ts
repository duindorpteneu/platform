import { afterEach, describe, expect, it, vi } from "vitest";
import {
  brandCssVariables,
  getPublishedBrandCssVariables,
} from "./public-tokens";

describe("public branding tokens", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    delete process.env.NEXT_PUBLIC_SUPABASE_URL;
    delete process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  });

  it("zet de drie gepubliceerde hexkleuren exact om naar CSS-rgbtokens", () => {
    expect(brandCssVariables({
      primaryColor: "#17418B",
      secondaryColor: "#0B2E63",
      accentColor: "#2E69CC",
    })).toEqual({
      "--brand-500-rgb": "46 105 204",
      "--brand-700-rgb": "23 65 139",
      "--brand-900-rgb": "11 46 99",
    });
  });

  it("gebruikt alleen een strikt geldig publiek databaseantwoord", async () => {
    process.env.NEXT_PUBLIC_SUPABASE_URL =
      "https://abcdefghijklmnopqrst.supabase.co";
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY = "publishable-test-key";
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: vi.fn().mockResolvedValue({
        primaryColor: "#123456",
        secondaryColor: "#234567",
        accentColor: "#345678",
      }),
    });
    vi.stubGlobal("fetch", fetchMock);
    expect(await getPublishedBrandCssVariables()).toEqual({
      "--brand-500-rgb": "52 86 120",
      "--brand-700-rgb": "18 52 86",
      "--brand-900-rgb": "35 69 103",
    });
    expect(fetchMock).toHaveBeenCalledWith(
      "https://abcdefghijklmnopqrst.supabase.co/rest/v1/rpc/get_public_brand_tokens_v1",
      expect.objectContaining({ method: "POST", cache: "no-store" }),
    );
  });

  it("valt zonder geldige publieke configuratie terug op de designcanon", async () => {
    expect(await getPublishedBrandCssVariables()).toEqual({
      "--brand-500-rgb": "46 105 204",
      "--brand-700-rgb": "23 65 139",
      "--brand-900-rgb": "11 46 99",
    });
  });
});
