import { describe, expect, it } from "vitest";
import { POST } from "./route";

function request(origin = "https://tenue.example") {
  return new Request("https://tenue.example/api/parent/packages/select", {
    method: "POST",
    headers: {
      origin,
      host: "tenue.example",
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
      "content-type": "application/json",
    },
    body: JSON.stringify({
      memberSeasonId: "10000000-0000-4000-8000-000000000001",
      packageRevisionId: "20000000-0000-4000-8000-000000000001",
    }),
  });
}

describe("POST /api/parent/packages/select", () => {
  it("weigert pakketkeuze door een ouder zonder mutatie", async () => {
    process.env.APP_BASE_URL = "https://tenue.example";
    const response = await POST(request());
    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({
      error: "Alleen de beheerder kan een kledingpakket toewijzen of wijzigen.",
    });
  });

  it("weigert cross-site verzoeken al bij de mutatiegrens", async () => {
    process.env.APP_BASE_URL = "https://tenue.example";
    expect((await POST(request("https://aanvaller.example"))).status).toBe(403);
  });
});
