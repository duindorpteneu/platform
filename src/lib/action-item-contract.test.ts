import { describe, expect, it } from "vitest";
import {
  actionItemAssignRequestSchema,
  actionItemDismissRequestSchema,
  actionItemQuerySchema,
  actionItemTarget,
  actionItemWorkspaceSchema,
} from "./action-item-contract";

const seasonId = "10000000-0000-4000-8000-000000000001";
const userId = "20000000-0000-4000-8000-000000000001";
const itemId = "30000000-0000-4000-8000-000000000001";

describe("action item contract", () => {
  it("rejects contradictory owner filters and unknown fields", () => {
    expect(actionItemQuerySchema.safeParse({
      seasonId,
      status: null,
      severity: null,
      ownerUserId: userId,
      onlyUnassigned: true,
      offset: 0,
      limit: 50,
    }).success).toBe(false);
    expect(actionItemAssignRequestSchema.safeParse({
      actionItemId: itemId,
      expectedRevision: 1,
      ownerUserId: null,
      force: true,
    }).success).toBe(false);
  });

  it("requires a substantive dismissal reason and positive revision", () => {
    expect(actionItemDismissRequestSchema.safeParse({
      actionItemId: itemId,
      expectedRevision: 0,
      reason: "x",
    }).success).toBe(false);
  });

  it("accepts only the bounded PII-free workspace projection", () => {
    const parsed = actionItemWorkspaceSchema.safeParse({
      tenantKey: "duindorp-sv",
      activeSeason: { id: seasonId, name: "2026/27" },
      selectedSeason: { id: seasonId, name: "2026/27", status: "open" },
      seasons: [{
        id: seasonId,
        name: "2026/27",
        status: "open",
        active: true,
      }],
      statusCounts: { open: 1, inProgress: 0, resolved: 0, dismissed: 0 },
      ownerOptions: [{
        userId,
        displayName: "Actiebeheer",
        role: "beheerder",
      }],
      viewer: { userId, role: "beheerder" },
      offset: 0,
      limit: 50,
      total: 1,
      items: [{
        id: itemId,
        type: "size_other",
        seasonId,
        objectType: "member_season",
        objectId: "40000000-0000-4000-8000-000000000001",
        sourceType: "size_selection",
        sourceId: null,
        episode: 1,
        severity: "warning",
        status: "open",
        visibility: "operations",
        reasonCode: "size_value_unknown",
        safeContext: {
          memberSeasonId: "40000000-0000-4000-8000-000000000001",
          attempt: 2,
          blocked: true,
        },
        ownerUserId: null,
        ownerDisplayName: null,
        openedAt: "2026-08-03T21:00:00+00:00",
        lastSeenAt: "2026-08-03T21:00:00+00:00",
        dueAt: null,
        assignedAt: null,
        startedAt: null,
        resolvedAt: null,
        resolutionReason: null,
        revision: 1,
        updatedAt: "2026-08-03T21:00:00+00:00",
        actions: {
          canAssign: true,
          canStart: true,
          canResolve: false,
          canDismiss: true,
        },
      }],
    });
    expect(parsed.success).toBe(true);

    const unsafe = structuredClone(parsed.success ? parsed.data : {});
    if ("items" in unsafe && Array.isArray(unsafe.items)) {
      unsafe.items[0].safeContext = { email: "ouder@example.invalid" };
    }
    expect(actionItemWorkspaceSchema.safeParse(unsafe).success).toBe(false);
  });

  it("routes herstelwerk naar het bijbehorende domeinscherm", () => {
    expect(actionItemTarget({
      type: "low_stock",
      objectType: "article_variant",
    })).toEqual({
      href: "/backoffice/leveringen",
      label: "Naar voorraad en leveringen",
    });
    expect(actionItemTarget({
      type: "payment_conflict",
      objectType: "package_order",
    }).href).toBe("/backoffice/betalingen");
  });
});
