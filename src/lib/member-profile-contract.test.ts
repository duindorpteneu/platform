import { describe, expect, it } from "vitest";
import {
  memberFamilyEmailPreflightRequestSchema,
  memberFamilyEmailPreflightResponseSchema,
  memberProfileUpdateRequestSchema,
} from "@/lib/member-profile-contract";

const valid = {
  memberId: "71000000-0000-4000-8000-000000000001",
  memberSeasonId: "72000000-0000-4000-8000-000000000001",
  firstName: "  Noor  ",
  insertion: " van ",
  lastName: " Dijk ",
  email: " OUDER@EXAMPLE.INVALID ",
  dateOfBirth: "2014-02-03",
  gender: "female",
  team: " O13-1 ",
  revision: "a".repeat(64),
  reason: " Correctie op verzoek ",
  requestId: "73000000-0000-4000-8000-000000000001",
};

describe("memberProfileUpdateRequestSchema", () => {
  it("normaliseert de invoerranden en accepteert alle profielvelden", () => {
    expect(memberProfileUpdateRequestSchema.parse(valid)).toMatchObject({
      firstName: "Noor",
      insertion: "van",
      lastName: "Dijk",
      email: "OUDER@EXAMPLE.INVALID",
      dateOfBirth: "2014-02-03",
      gender: "female",
      team: "O13-1",
      reason: "Correctie op verzoek",
    });
  });

  it("valideert de gezinsbrede preflight en alle zichtbare kinderen", () => {
    expect(memberFamilyEmailPreflightRequestSchema.safeParse({
      memberId: valid.memberId,
      memberSeasonId: valid.memberSeasonId,
      email: "nieuw@example.invalid",
      revision: valid.revision,
    }).success).toBe(true);
    expect(memberFamilyEmailPreflightResponseSchema.safeParse({
      portalAccessActive: true,
      transferRequired: true,
      currentMemberEmail: "oud@example.invalid",
      currentPortalEmail: "oud@example.invalid",
      newEmail: "nieuw@example.invalid",
      affectedMemberCount: 2,
      affectedMemberSeasonCount: 2,
      activePortalCount: 2,
      targetAccountReused: true,
      blockedCount: 0,
      affectedChildren: [{
        memberId: valid.memberId,
        memberSeasonId: valid.memberSeasonId,
        memberName: "Noor van Dijk",
        team: "O13-1",
      }],
      familyRevision: "b".repeat(64),
    }).success).toBe(true);
  });

  it("maakt optionele lege velden expliciet null", () => {
    expect(memberProfileUpdateRequestSchema.parse({
      ...valid,
      insertion: " ",
      email: "",
      dateOfBirth: "",
      team: " ",
    })).toMatchObject({ insertion: null, email: null, dateOfBirth: null, team: null });
  });

  it("weigert toekomstige geboortedata en onbekende velden", () => {
    expect(memberProfileUpdateRequestSchema.safeParse({
      ...valid,
      dateOfBirth: "2999-01-01",
    }).success).toBe(false);
    expect(memberProfileUpdateRequestSchema.safeParse({
      ...valid,
      hidden: "waarde",
    }).success).toBe(false);
  });
});
