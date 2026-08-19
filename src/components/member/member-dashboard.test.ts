import { describe, expect, it } from "vitest";
import type { ParentPackageMember } from "@/lib/parent-package-contract";
import {
  buildPackageSizeSelections,
  canStartPayment,
  initialSizeDraft,
  packageSizeAction,
} from "./member-dashboard";

const articleId = "10000000-0000-4000-8000-000000000001";
const variantId = "20000000-0000-4000-8000-000000000001";

const item = {
  snapshotItemId: "30000000-0000-4000-8000-000000000001",
  articleId,
  name: "Shirt",
  code: "SHIRT",
  iconType: "shirt" as const,
  quantity: 1,
  selectedVariantId: variantId,
  selectionStatus: "imported_unconfirmed" as const,
  selectionSource: "import" as const,
  rawValue: null,
  memberNote: null,
  confirmedAt: null,
  requestedVariantId: null,
  requestedRawValue: null,
  requestedMemberNote: null,
  lineStatus: null,
  hasReservation: false,
  issued: false,
  variants: [{ id: variantId, label: "152", active: true }],
};

const member = {
  memberId: "40000000-0000-4000-8000-000000000001",
  memberSeasonId: "50000000-0000-4000-8000-000000000001",
  relationNumber: null,
  firstName: "Noa",
  insertion: null,
  lastName: "Duin",
  team: "JO13-1",
  dateOfBirth: "2013-05-17",
  gender: "female",
  seasonId: "60000000-0000-4000-8000-000000000001",
  seasonName: "2026/2027",
  availablePackages: [],
  revision: "a".repeat(64),
  order: {
    id: "70000000-0000-4000-8000-000000000001",
    amountDueCents: 12500,
    paymentStatus: "open",
    orderStatus: "Nog niet betaald",
    qrVersion: null,
    packageRevisionId: "80000000-0000-4000-8000-000000000001",
    packageName: "Speler",
    packageDescription: null,
    packagePriceCents: 12500,
    currency: "EUR",
    revisionLabel: "Speler v1",
    legacy: false,
    canSwitchPackage: true,
    sizesConfirmed: false,
    revision: "a".repeat(64),
    articleLines: [],
    items: [item],
    qrDataUrl: null,
  },
} satisfies ParentPackageMember;

describe("MemberDashboard package sizes", () => {
  it("zet een geïmporteerde geldige maat klaar zonder die al te bevestigen", () => {
    expect(initialSizeDraft(item)).toEqual({
      kind: "variant",
      variantId,
      note: "",
    });
  });

  it("bouwt alleen een volledig pakketbreed selectiecontract", () => {
    expect(
      buildPackageSizeSelections(member, {
        [articleId]: { kind: "variant", variantId, note: "" },
      }),
    ).toEqual([
      {
        articleId,
        kind: "variant",
        variantId,
        note: null,
      },
    ]);
    expect(
      buildPackageSizeSelections(member, {
        [articleId]: { kind: "", variantId: null, note: "" },
      }),
    ).toBeNull();
  });

  it("vereist een toelichting voor Anders en maakt geen variant", () => {
    expect(
      buildPackageSizeSelections(member, {
        [articleId]: {
          kind: "other",
          variantId: null,
          note: "Valt buiten de maattabel",
        },
      }),
    ).toEqual([
      {
        articleId,
        kind: "other",
        variantId: null,
        note: "Valt buiten de maattabel",
      },
    ]);
  });

  it("houdt betaling onafhankelijk van de maatbevestiging", () => {
    expect(canStartPayment(member)).toBe(true);
    expect(
      canStartPayment({
        ...member,
        order: member.order ? { ...member.order, sizesConfirmed: true } : null,
      }),
    ).toBe(true);
    expect(
      canStartPayment({
        ...member,
        order: member.order ? { ...member.order, legacy: true } : null,
      }),
    ).toBe(false);
  });

  it("onderscheidt invullen van geïmporteerde maten controleren", () => {
    expect(packageSizeAction(member)).toBe("review");
    expect(
      packageSizeAction({
        ...member,
        order: member.order
          ? {
              ...member.order,
              items: [
                {
                  ...item,
                  selectedVariantId: null,
                  selectionStatus: null,
                  selectionSource: null,
                },
              ],
            }
          : null,
      }),
    ).toBe("fill");
    expect(
      packageSizeAction({
        ...member,
        order: member.order ? { ...member.order, sizesConfirmed: true } : null,
      }),
    ).toBe("review");
    expect(
      packageSizeAction({
        ...member,
        order: member.order
          ? {
              ...member.order,
              sizesConfirmed: true,
              items: [{ ...item, selectionStatus: "locked" }],
            }
          : null,
      }),
    ).toBeNull();
  });
});
