import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const contract = readFileSync(new URL("./sql/operational-cleanup-contract.sql", import.meta.url), "utf8");
const apply = readFileSync(new URL("./sql/operational-cleanup-apply.sql", import.meta.url), "utf8");
const shell = readFileSync(new URL("./cleanup-operational-data.sh", import.meta.url), "utf8");
const workflow = readFileSync(new URL("../../.github/workflows/staging-domain-cleanup.yml", import.meta.url), "utf8");

describe("staging domain cleanup contract", () => {
  it("gebruikt een gesloten schema-inventaris en raakt staff/Auth niet", () => {
    expect(contract).toContain("cardinality(pg_temp.cleanup_tables()) <> 90");
    expect(contract).toContain("cardinality(pg_temp.preserved_tables()) <> 27");
    expect(contract).toContain("actual_tables is distinct from contracted_tables");
    expect(contract).toContain("'app.staff_profiles' = any(pg_temp.cleanup_tables())");
    expect(contract).not.toMatch(/'auth\.[a-z_]+',/u);
  });

  it("lockt vóór digestcontrole en truncate, zonder cascade", () => {
    const lock = apply.indexOf("in access exclusive mode");
    const digest = apply.indexOf("operational state changed after the verified backup");
    const truncate = apply.indexOf("'truncate table '");
    expect(lock).toBeGreaterThan(0);
    expect(digest).toBeGreaterThan(lock);
    expect(truncate).toBeGreaterThan(digest);
    expect(apply.toLowerCase()).not.toContain("truncate table app.staff_profiles");
    expect(apply.toLowerCase()).not.toContain(" cascade");
  });

  it("bewaart audit en bewijst staff, Auth en configuratie na commit", () => {
    expect(apply).toContain("staging.domain_cleanup.completed");
    expect(apply).toContain("pg_temp.preserved_state_digest()");
    expect(apply).toContain("pg_temp.staff_profile_digest()");
    expect(apply).toContain("pg_temp.auth_user_id_digest()");
    expect(apply).toContain("profile.auth_user_id");
  });

  it("herstelt de versleutelde dump netwerkloos vóór de mutatie", () => {
    const encrypt = shell.indexOf("--symmetric --cipher-algo AES256");
    const decrypt = shell.indexOf("--decrypt --output");
    const isolated = shell.indexOf("--network none");
    const restore = shell.indexOf("pg_restore --exit-on-error");
    const applySql = shell.indexOf("operational-cleanup-apply.sql");
    expect(encrypt).toBeGreaterThan(0);
    expect(decrypt).toBeGreaterThan(encrypt);
    expect(isolated).toBeGreaterThan(decrypt);
    expect(restore).toBeGreaterThan(isolated);
    expect(applySql).toBeGreaterThan(restore);
  });

  it("draait apply alleen op de stagingrunner en serialiseert met deploy", () => {
    expect(workflow).toContain("group: deploy-duindorpteneu-staging");
    expect(workflow).toContain("- staging");
    expect(workflow).toContain("STAGING_CLEANUP_BACKUP_PASSPHRASE");
    expect(workflow).toContain("ref: ${{ inputs.release_sha }}");
    expect(workflow).not.toContain("production");
  });
});
