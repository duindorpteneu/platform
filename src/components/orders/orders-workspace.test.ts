import { describe, expect, it } from "vitest";
import type { CatalogOrderWorkspace as Workspace } from "@/lib/catalog-order-contract";
import {
  isLegacyOrder,
  requestedSizeLabel,
} from "./orders-workspace";

const id = "10000000-0000-4000-8000-000000000001";
const secondId = "10000000-0000-4000-8000-000000000002";

const member: Workspace["members"][number] = {
  id,
  name: "Voornaam Lid",
  relationNumber: "DSV-1",
  team: "JO13-1",
  order: {
    id,
    amountDueCents: 12_500,
    paid: false,
    lines: [],
  },
};

const packageOrder: Workspace["packageOrders"][number] = {
  memberId: id,
  memberSeasonId: secondId,
  orderId: id,
  packageRevisionId: secondId,
  packageName: "Speler",
  canSwitchPackage: true,
  revision: "a".repeat(64),
};

describe("pakketorderbeheer", () => {
  it("houdt alleen aantoonbare losse historische orders in de legacy-editor", () => {
    expect(isLegacyOrder(member, packageOrder)).toBe(false);
    expect(isLegacyOrder(member, {
      ...packageOrder,
      packageRevisionId: null,
      packageName: null,
    })).toBe(true);
    expect(isLegacyOrder({ ...member, order: null }, null)).toBe(false);
  });

  it("toont een concrete maat of expliciet Anders", () => {
    const base = {
      requestId: id,
      memberId: id,
      memberSeasonId: secondId,
      memberName: "Voornaam Lid",
      team: "JO13-1",
      articleId: id,
      articleName: "Broek",
      currentVariantId: id,
      currentSize: "152",
      requestedAt: "2026-08-02T10:00:00+00:00",
      revision: "a".repeat(64),
      variants: [{ id: secondId, label: "164" }],
    };

    expect(requestedSizeLabel({
      ...base,
      requestedKind: "variant",
      requestedVariantId: secondId,
      requestedSize: "164",
      requestedRawValue: null,
      requestedMemberNote: null,
    })).toBe("164");
    expect(requestedSizeLabel({
      ...base,
      requestedKind: "other",
      requestedVariantId: null,
      requestedSize: null,
      requestedRawValue: "Anders…",
      requestedMemberNote: "Langere maat nodig",
    })).toBe("Anders…");
  });
});
