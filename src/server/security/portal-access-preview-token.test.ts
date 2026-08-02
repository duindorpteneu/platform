import { describe, expect, it } from "vitest";
import {
  createPortalAccessPreviewToken,
  portalAccessSelectionDigest,
  verifyPortalAccessPreviewToken,
} from "@/server/security/portal-access-preview-token";

const pepper = "portal-access-preview-test-pepper-32-characters";
const actorId = "10000000-0000-4000-8000-000000000001";
const seasonId = "20000000-0000-4000-8000-000000000001";
const ids = [
  "30000000-0000-4000-8000-000000000002",
  "30000000-0000-4000-8000-000000000001",
];

describe("portal access preview token", () => {
  it("binds actor, operation, season, selection and database revision", () => {
    const token = createPortalAccessPreviewToken({
      operation: "activate",
      actorId,
      seasonId,
      ids,
      revision: "a".repeat(64),
    }, pepper, 1_000);
    expect(verifyPortalAccessPreviewToken(token, pepper, {
      operation: "activate",
      actorId,
      seasonId,
      ids: [...ids].reverse(),
    }, 2_000)).toMatchObject({
      operation: "activate",
      actorId,
      seasonId,
      revision: "a".repeat(64),
    });
  });

  it("contains only a selection digest and rejects mismatches or expiry", () => {
    const token = createPortalAccessPreviewToken({
      operation: "revoke",
      actorId,
      seasonId,
      ids,
      revision: "b".repeat(64),
    }, pepper, 1_000);
    const encoded = token.split(".")[0];
    const decoded = JSON.parse(Buffer.from(encoded, "base64url").toString("utf8"));
    expect(decoded.selectionDigest).toBe(portalAccessSelectionDigest("revoke", seasonId, ids));
    expect(JSON.stringify(decoded)).not.toContain(ids[0]);
    expect(() => verifyPortalAccessPreviewToken(token, pepper, {
      operation: "activate",
      actorId,
      seasonId,
      ids,
    }, 2_000)).toThrow("PORTAL_ACCESS_PREVIEW_TOKEN_MISMATCH");
    expect(() => verifyPortalAccessPreviewToken(token, pepper, {
      operation: "revoke",
      actorId,
      seasonId,
      ids,
    }, 10 * 60 * 1000 + 1_001)).toThrow("PORTAL_ACCESS_PREVIEW_TOKEN_EXPIRED");
  });

  it("rejects tampering and weak configuration", () => {
    const token = createPortalAccessPreviewToken({
      operation: "activate",
      actorId,
      seasonId,
      ids,
      revision: "c".repeat(64),
    }, pepper);
    expect(() => verifyPortalAccessPreviewToken(`${token}x`, pepper, {
      operation: "activate",
      actorId,
      seasonId,
      ids,
    })).toThrow("PORTAL_ACCESS_PREVIEW_TOKEN_INVALID");
    expect(() => createPortalAccessPreviewToken({
      operation: "activate",
      actorId,
      seasonId,
      ids,
      revision: "c".repeat(64),
    }, "short")).toThrow("PORTAL_ACCESS_PREVIEW_PEPPER_MISSING");
  });
});
