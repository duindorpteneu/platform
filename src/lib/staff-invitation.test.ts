import { describe, expect, it } from "vitest";
import { parseStaffInvitationFragment } from "@/lib/staff-invitation";

describe("staff invitation fragment", () => {
  it("accepts only an invite session and returns no unrelated fragment fields", () => {
    expect(parseStaffInvitationFragment("#access_token=header.payload.signature&refresh_token=refresh_token_12345&type=invite&expires_in=3600")).toEqual({
      accessToken: "header.payload.signature",
      refreshToken: "refresh_token_12345",
    });
  });

  it("rejects missing, malformed and non-invite sessions", () => {
    expect(parseStaffInvitationFragment("#type=recovery&access_token=header.payload.signature&refresh_token=refresh_token_12345")).toBeNull();
    expect(parseStaffInvitationFragment("#type=invite&access_token=header.payload.signature")).toBeNull();
    expect(parseStaffInvitationFragment("#type=invite&access_token=contains%20space&refresh_token=refresh_token_12345")).toBeNull();
  });
});
