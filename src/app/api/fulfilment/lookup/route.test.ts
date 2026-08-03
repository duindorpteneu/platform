import { describe, expect, it } from "vitest";
import { POST } from "./route";

describe("POST /api/fulfilment/lookup", () => {
  it("permanently rejects the legacy reusable bearer route", async () => {
    const response = await POST(new Request(
      "https://tenue.example/api/fulfilment/lookup",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ token: `v1.${"a".repeat(43)}` }),
      },
    ));
    expect(response.status).toBe(410);
    expect(response.headers.get("Cache-Control")).toContain("no-store");
    expect(JSON.stringify(await response.json())).not.toContain("token");
  });
});
