import { describe, expect, it } from "vitest";
import {
  parentPackageSizesRequestSchema,
  parentPackageWorkspaceDatabaseSchema,
  staffPackageSelectionRequestSchema,
  staffPackageSelectionResponseSchema,
  type ParentPackageWorkspaceDatabase,
} from "./parent-package-contract";

const memberSeasonId = "10000000-0000-4000-8000-000000000001";
const memberId = "20000000-0000-4000-8000-000000000001";
const seasonId = "30000000-0000-4000-8000-000000000001";
const articleId = "40000000-0000-4000-8000-000000000001";
const variantId = "50000000-0000-4000-8000-000000000001";

function workspace(): ParentPackageWorkspaceDatabase {
  return {
    enabled: true,
    members: [{
      memberId,
      memberSeasonId,
      relationNumber: "REL-1",
      firstName: "Noa",
      insertion: null,
      lastName: "Duin",
      team: "JO13-1",
      dateOfBirth: "2013-05-17",
      gender: "female",
      seasonId,
      seasonName: "2026/2027",
      availablePackages: [],
      order: null,
      revision: "a".repeat(64),
    }],
  };
}

describe("parent package contract", () => {
  it("accepteert DOB uitsluitend binnen het expliciete lid-seizoencontract", () => {
    expect(parentPackageWorkspaceDatabaseSchema.parse(workspace()).members[0])
      .toMatchObject({ dateOfBirth: "2013-05-17", memberSeasonId });
  });

  it("weigert onverwachte databasevelden zodat nieuwe PII niet stil uitlekt", () => {
    const input = workspace();
    Object.assign(input.members[0], { email: "niet-doorsturen@example.invalid" });
    expect(parentPackageWorkspaceDatabaseSchema.safeParse(input).success).toBe(false);
  });

  it("vereist een canoniek artikelicoon voor ieder pakketproduct", () => {
    const input = workspace();
    input.members[0].availablePackages = [{
      revisionId: variantId,
      name: "Speler",
      description: null,
      priceCents: 12_500,
      currency: "EUR",
      revisionNumber: 1,
      isDefault: true,
      items: [{
        articleId,
        name: "Shirt",
        code: "SHIRT",
        iconType: "shirt",
        quantity: 1,
      }],
    }];
    expect(parentPackageWorkspaceDatabaseSchema.safeParse(input).success)
      .toBe(true);
    delete (input.members[0].availablePackages[0].items[0] as {
      iconType?: string;
    }).iconType;
    expect(parentPackageWorkspaceDatabaseSchema.safeParse(input).success)
      .toBe(false);
  });

  it("modelleert Anders uitsluitend als conflict met toelichting", () => {
    const base = {
      memberSeasonId,
      revision: "b".repeat(64),
      requestId: "60000000-0000-4000-8000-000000000001",
    };
    expect(parentPackageSizesRequestSchema.safeParse({
      ...base,
      selections: [{
        articleId,
        kind: "other",
        variantId: null,
        note: "Valt buiten de maattabel",
      }],
    }).success).toBe(true);
    expect(parentPackageSizesRequestSchema.safeParse({
      ...base,
      selections: [{
        articleId,
        kind: "other",
        variantId,
        note: null,
      }],
    }).success).toBe(false);
  });

  it("weigert dubbele pakketproducten vóór de transactierand", () => {
    expect(parentPackageSizesRequestSchema.safeParse({
      memberSeasonId,
      revision: "b".repeat(64),
      requestId: "60000000-0000-4000-8000-000000000001",
      selections: [
        { articleId, kind: "variant", variantId, note: null },
        { articleId, kind: "variant", variantId, note: null },
      ],
    }).success).toBe(false);
  });

  it("vereist een idempotency-id en een expliciete reused-response", () => {
    const request = {
      memberSeasonId,
      packageRevisionId: variantId,
      revision: "b".repeat(64),
      reason: "Pakket gekozen na controle",
      requestId: "60000000-0000-4000-8000-000000000001",
    };
    expect(staffPackageSelectionRequestSchema.safeParse(request).success)
      .toBe(true);
    expect(staffPackageSelectionRequestSchema.safeParse({
      ...request,
      requestId: undefined,
    }).success).toBe(false);
    expect(staffPackageSelectionResponseSchema.safeParse({
      memberSeasonId,
      orderId: "70000000-0000-4000-8000-000000000001",
      packageRevisionId: variantId,
      changed: true,
      revision: "c".repeat(64),
      reused: false,
    }).success).toBe(true);
  });
});
