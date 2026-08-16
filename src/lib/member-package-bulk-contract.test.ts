import { describe, expect, it } from "vitest";
import { memberPackageBulkRequestSchema, memberPackageBulkResponseSchema } from "@/lib/member-package-bulk-contract";

const memberSeasonId = "aa000000-0000-4000-8000-000000000001";
const packageRevisionId = "ab000000-0000-4000-8000-000000000001";

describe("member package bulk contract", () => {
  it("accepteert een begrensde expliciete toewijzing", () => {
    expect(memberPackageBulkRequestSchema.safeParse({
      action: "assign",
      scope: "selected",
      memberSeasonIds: [memberSeasonId],
      packageRevisionId,
      reason: "Pakket toewijzen",
      requestId: "ac000000-0000-4000-8000-000000000001",
      commit: false,
    }).success).toBe(true);
  });

  it("weigert dubbele leden en een pakket-ID bij verwijderen", () => {
    expect(memberPackageBulkRequestSchema.safeParse({
      action: "remove",
      scope: "selected",
      memberSeasonIds: [memberSeasonId, memberSeasonId],
      packageRevisionId,
      reason: "Pakket verwijderen",
      requestId: "ac000000-0000-4000-8000-000000000001",
      commit: false,
    }).success).toBe(false);
  });

  it("weigert preflightaantallen die niet optellen", () => {
    expect(memberPackageBulkResponseSchema.safeParse({
      action: "assign",
      scope: "all_active",
      seasonId: "ac000000-0000-4000-8000-000000000001",
      packageRevisionId,
      requestedCount: 5,
      matchedCount: 5,
      eligibleCount: 2,
      unchangedCount: 1,
      blockedCount: 1,
      inactiveOrInvalidCount: 0,
      linkedSizeCount: 2,
      missingSizeCount: 2,
      committed: false,
      previewToken: "preview",
    }).success).toBe(false);
  });
});
