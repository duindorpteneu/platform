import { describe, expect, it } from "vitest";
import { parseStaffInvitationFragment, parseStaffRecoveryFragment, resolveStaffRecoveryRedirect } from "@/lib/staff-invitation";

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

  it("separates recovery sessions from invitations", () => {
    const recovery = "#type=recovery&access_token=header.payload.signature&refresh_token=refresh_token_12345";
    expect(parseStaffRecoveryFragment(recovery)).toEqual({
      accessToken: "header.payload.signature",
      refreshToken: "refresh_token_12345",
    });
    expect(parseStaffInvitationFragment(recovery)).toBeNull();
    expect(parseStaffRecoveryFragment(recovery.replace("recovery", "invite"))).toBeNull();
  });

  it("routes a Supabase Site URL recovery fallback to the staff reset surface", () => {
    const recovery = "#type=recovery&access_token=header.payload.signature&refresh_token=refresh_token_12345";
    expect(resolveStaffRecoveryRedirect("/login", recovery)).toBe(`/staff/reset-password${recovery}`);
    expect(resolveStaffRecoveryRedirect("/staff/reset-password", recovery)).toBeNull();
    expect(resolveStaffRecoveryRedirect("/login", recovery.replace("recovery", "invite"))).toBeNull();
  });
});
