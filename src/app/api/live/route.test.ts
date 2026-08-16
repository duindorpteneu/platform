import { describe, expect, it } from "vitest";
import { GET } from "./route";

describe("GET /api/live", () => {
  it("reports process liveness without weakening operational readiness", async () => {
    const response = await GET();

    expect(response.status).toBe(200);
    expect(response.headers.get("cache-control")).toBe("no-store");
    expect(await response.json()).toEqual({
      status: "alive",
      service: "duindorpteneu",
    });
  });
});
