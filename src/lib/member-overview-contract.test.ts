import { describe, expect, it } from "vitest";
import {
  memberDetailResponseSchema,
  memberListQuerySchema,
  memberListResponseSchema,
  memberStatusRequestSchema,
  teamMemberStatusRequestSchema,
  teamMemberStatusResponseSchema,
} from "@/lib/member-overview-contract";

const season = { id: "71000000-0000-4000-8000-000000000001", name: "2026/27" };
const order = {
  id: "75000000-0000-4000-8000-000000000001",
  amountDueCents: 12500,
  paymentStatus: "Betaald",
  orderStatus: "Gedeeltelijk af te halen",
  progressQuantity: 1,
  totalQuantity: 2,
};
const list = {
  activeSeason: season,
  totalCount: 1,
  activeCount: 1,
  filteredCount: 1,
  filterOptions: { teams: ["JO11-1"], articles: [{ id: "72000000-0000-4000-8000-000000000001", name: "Shirt" }], sizes: ["M"] },
  members: [{
    id: "74000000-0000-4000-8000-000000000001",
    memberName: "Sophie Tester",
    relationNumber: "LED-001",
    team: "JO11-1",
    activeForSeason: true,
    updatedAt: "2026-07-18T12:00:00.000Z",
    order,
  }],
};
const detail = {
  id: list.members[0].id,
  memberName: "Sophie Tester",
  firstName: "Sophie",
  insertion: null,
  lastName: "Tester",
  relationNumber: "LED-001",
  email: "ouder@example.invalid",
  team: "JO11-1",
  activeForSeason: true,
  updatedAt: "2026-07-18T12:00:00.000Z",
  activeSeason: season,
  parentLinks: [{ id: "77000000-0000-4000-8000-000000000001", email: "ouder@example.invalid", linkedAt: "2026-07-18T12:00:00.000Z" }],
  order: {
    id: order.id,
    amountDueCents: order.amountDueCents,
    paymentStatus: order.paymentStatus,
    orderStatus: order.orderStatus,
    paidAt: "2026-07-18T12:00:00.000Z",
    qrStatus: "Actief",
    lines: [{ id: "76000000-0000-4000-8000-000000000001", article: "Shirt", size: "M", quantity: 1, status: "ready_for_pickup" }],
  },
  activities: [],
};

describe("member overview contract", () => {
  it("requires an explicit reason for a member status change", () => {
    expect(memberStatusRequestSchema.safeParse({ memberId: list.members[0].id, active: false, reason: "Afgemeld voor dit seizoen" }).success).toBe(true);
    expect(memberStatusRequestSchema.safeParse({ memberId: list.members[0].id, active: false, reason: "" }).success).toBe(false);
  });
  it("requires a reason only when a team status change is committed", () => {
    expect(teamMemberStatusRequestSchema.safeParse({ team: " JO11-1 ", active: false, commit: false }).success).toBe(true);
    expect(teamMemberStatusRequestSchema.safeParse({ team: "JO11-1", active: false, commit: true }).success).toBe(false);
    expect(teamMemberStatusRequestSchema.safeParse({ team: "JO11-1", active: true, reason: "Nieuwe teamindeling", commit: true }).success).toBe(true);
    expect(teamMemberStatusResponseSchema.safeParse({ seasonId: season.id, team: "JO11-1", totalMembers: 18, changedMembers: 17, unchangedMembers: 1, activeForSeason: true, committed: true }).success).toBe(true);
  });
  it("normalizes safe URL filters", () => {
    expect(memberListQuerySchema.parse({ search: "  Sophie ", page: "2" })).toMatchObject({ search: "Sophie", page: 2 });
    expect(memberListQuerySchema.parse({ team: "JO13-2", payment: "", orderStatus: "", articleId: "", lineStatus: "" })).toMatchObject({ team: "JO13-2" });
  });

  it("rejects arbitrary filters and identifiers", () => {
    expect(memberListQuerySchema.safeParse({ payment: "partial" }).success).toBe(false);
    expect(memberListQuerySchema.safeParse({ member: "not-an-id" }).success).toBe(false);
  });

  it("accepts a minimal list without e-mail", () => {
    expect(memberListResponseSchema.safeParse(list).success).toBe(true);
  });

  it("rejects PII added to a list row", () => {
    expect(memberListResponseSchema.safeParse({ ...list, members: [{ ...list.members[0], email: "ouder@example.invalid" }] }).success).toBe(false);
  });

  it("accepts operationele detaildata but rejects a QR token", () => {
    expect(memberDetailResponseSchema.safeParse(detail).success).toBe(true);
    expect(memberDetailResponseSchema.safeParse({ ...detail, order: { ...detail.order, qrToken: "secret" } }).success).toBe(false);
  });
});
