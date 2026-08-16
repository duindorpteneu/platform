import { describe, expect, it } from "vitest";
import { BODY_POLICIES, guardBrowserMutation } from "./route-guard";

const appBaseUrl = "https://tenue.duindorpsv.nl";

function request(method: string, origin = appBaseUrl) {
  return new Request(`${appBaseUrl}/api/stock/drafts/example`, {
    method,
    headers: {
      host: "tenue.duindorpsv.nl",
      origin,
      "sec-fetch-site": "same-origin",
      "x-duindorp-csrf": "same-origin",
      "content-type": "application/json",
    },
    body: method === "GET" ? undefined : JSON.stringify({ revision: 1 }),
  });
}

describe("guardBrowserMutation", () => {
  it("laat een correct beveiligde PUT voor leveringconcepten door", () => {
    expect(guardBrowserMutation(request("PUT"), {
      appBaseUrl,
      body: BODY_POLICIES.jsonStandard,
    })).toBeNull();
  });

  it("blijft cross-origin PUT-verzoeken weigeren", async () => {
    const response = guardBrowserMutation(request("PUT", "https://attacker.example"), {
      appBaseUrl,
      body: BODY_POLICIES.jsonStandard,
    });

    expect(response?.status).toBe(403);
    await expect(response?.json()).resolves.toEqual({
      error: "Dit verzoek kon niet veilig worden gecontroleerd.",
    });
  });
});
