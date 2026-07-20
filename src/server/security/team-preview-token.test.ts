import { describe, expect, it } from "vitest";
import { createTeamPreviewToken, verifyTeamPreviewToken } from "@/server/security/team-preview-token";

const pepper = "team-preview-test-pepper-with-more-than-32-characters";
const common = { team: "JO11-1", seasonId: "71000000-0000-4000-8000-000000000001", revision: "a".repeat(64) };

describe("team preview token", () => {
  it("bindt de teamstatus aan seizoen, snapshot en vervaltijd", () => {
    const token = createTeamPreviewToken({ operation: "member-status", ...common, active: false }, pepper, 1_000);
    expect(verifyTeamPreviewToken(token, pepper, 2_000)).toMatchObject({ operation: "member-status", ...common, active: false });
    expect(() => verifyTeamPreviewToken(token, pepper, 602_000)).toThrow("TEAM_PREVIEW_TOKEN_EXPIRED");
  });

  it("sorteert variant-ID's en weigert manipulatie", () => {
    const ids = ["72000000-0000-4000-8000-000000000002", "72000000-0000-4000-8000-000000000001"];
    const token = createTeamPreviewToken({ operation: "order-articles", ...common, variantIds: ids }, pepper, 1_000);
    expect(verifyTeamPreviewToken(token, pepper, 2_000)).toMatchObject({ variantIds: [...ids].sort() });
    expect(() => verifyTeamPreviewToken(`${token}x`, pepper, 2_000)).toThrow("TEAM_PREVIEW_TOKEN_INVALID");
  });
});
