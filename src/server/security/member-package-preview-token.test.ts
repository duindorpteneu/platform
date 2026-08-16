import { describe, expect, it } from "vitest";
import {
  createMemberPackagePreviewToken,
  verifyMemberPackagePreviewToken,
} from "@/server/security/member-package-preview-token";

const pepper = "member-package-preview-pepper-with-at-least-32-characters";
const memberSeasonIds = [
  "aa000000-0000-4000-8000-000000000002",
  "aa000000-0000-4000-8000-000000000001",
];

describe("member package preview token", () => {
  it("bindt selectie, pakket, reden, seizoen en revision in vaste volgorde", () => {
    const token = createMemberPackagePreviewToken({
      action: "assign",
      scope: "selected",
      memberSeasonIds,
      packageRevisionId: "ab000000-0000-4000-8000-000000000001",
      reason: "Pakket gekozen door beheerder",
      seasonId: "ac000000-0000-4000-8000-000000000001",
      revision: "a".repeat(64),
    }, pepper, 1_000);
    expect(verifyMemberPackagePreviewToken(token, pepper, 2_000)).toMatchObject({
      memberSeasonIds: [...memberSeasonIds].sort(),
      reason: "Pakket gekozen door beheerder",
    });
  });

  it("weigert manipulatie en verlopen tokens", () => {
    const token = createMemberPackagePreviewToken({
      action: "remove",
      scope: "all_active",
      memberSeasonIds: [],
      packageRevisionId: null,
      reason: "Veilig intrekken voor betaling",
      seasonId: "ac000000-0000-4000-8000-000000000001",
      revision: "b".repeat(64),
    }, pepper, 1_000);
    expect(() => verifyMemberPackagePreviewToken(`${token}x`, pepper, 2_000)).toThrow("MEMBER_PACKAGE_PREVIEW_TOKEN_INVALID");
    expect(() => verifyMemberPackagePreviewToken(token, pepper, 602_000)).toThrow("MEMBER_PACKAGE_PREVIEW_TOKEN_EXPIRED");
  });
});
