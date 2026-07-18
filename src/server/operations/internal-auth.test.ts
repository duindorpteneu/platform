import { afterEach, describe, expect, it } from "vitest";
import { hasInternalBearer } from "@/server/operations/internal-auth";

describe("internal bearer auth", () => {
  afterEach(() => { delete process.env.CRON_SECRET; });
  it("fails closed without configuration or with an incorrect secret", () => {
    expect(hasInternalBearer(new Request("https://portal.test"))).toBe(false);
    process.env.CRON_SECRET = "0123456789abcdef";
    expect(hasInternalBearer(new Request("https://portal.test", { headers: { authorization: "Bearer wrong" } }))).toBe(false);
  });
  it("accepts the exact configured bearer", () => {
    process.env.CRON_SECRET = "0123456789abcdef";
    expect(hasInternalBearer(new Request("https://portal.test", { headers: { authorization: "Bearer 0123456789abcdef" } }))).toBe(true);
  });
});

