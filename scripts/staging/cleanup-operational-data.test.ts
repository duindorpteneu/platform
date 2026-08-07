import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const contract = readFileSync(new URL("./sql/operational-cleanup-contract.sql", import.meta.url), "utf8");
const apply = readFileSync(new URL("./sql/operational-cleanup-apply.sql", import.meta.url), "utf8");
const shell = readFileSync(new URL("./cleanup-operational-data.sh", import.meta.url), "utf8");
const workflow = readFileSync(new URL("../../.github/workflows/staging-domain-cleanup.yml", import.meta.url), "utf8");

describe("staging domain cleanup contract", () => {
  it("gebruikt een gesloten schema-inventaris en raakt staff/Auth niet", () => {
    const cleanupArray = contract.slice(
      contract.indexOf("select array["),
      contract.indexOf("]::text[]"),
    );
    const cleanupTables = [
      ...cleanupArray.matchAll(
        /'((?:app|private)\.[a-z][a-z0-9_]*)'/gu,
      ),
    ].map((match) => match[1]);
    expect(cleanupTables).toHaveLength(100);
    expect(new Set(cleanupTables)).toHaveLength(100);
    expect(contract).toContain("cardinality(pg_temp.cleanup_tables()) <> 100");
    expect(contract).toContain("cardinality(pg_temp.preserved_tables()) <> 28");
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
    expect(apply).toContain("duindorp.cleanup.backup_artifact_id");
    expect(apply).toContain("profile.auth_user_id");
    const committedEvidence = shell.indexOf("export RUNTIME_RECOVERY_PROVEN=false");
    const exactRestoreEvidence = shell.indexOf("export EXACT_RESTORE_PROVEN=true");
    const restart = shell.indexOf("\nrestart_staging\n", committedEvidence);
    const recoveredEvidence = shell.indexOf("export RUNTIME_RECOVERY_PROVEN=true");
    expect(committedEvidence).toBeGreaterThan(0);
    expect(exactRestoreEvidence).toBeGreaterThan(0);
    expect(exactRestoreEvidence).toBeLessThan(committedEvidence);
    expect(restart).toBeGreaterThan(committedEvidence);
    expect(recoveredEvidence).toBeGreaterThan(restart);
    expect(workflow).toContain(
      "- name: Upload redacted cleanup evidence\n        if: always()",
    );
  });

  it("herstelt de versleutelde dump netwerkloos vóór de mutatie", () => {
    const encrypt = shell.indexOf("--symmetric --cipher-algo AES256");
    const decrypt = shell.indexOf("--decrypt --output");
    const isolated = shell.indexOf("--network none");
    const restore = shell.indexOf("pg_restore");
    const exactInventory = shell.indexOf(
      "validate-source-restore-inventory.mjs",
    );
    const applySql = shell.indexOf("operational-cleanup-apply.sql");
    expect(encrypt).toBeGreaterThan(0);
    expect(decrypt).toBeGreaterThan(encrypt);
    expect(isolated).toBeGreaterThan(decrypt);
    expect(restore).toBeGreaterThan(isolated);
    expect(exactInventory).toBeGreaterThan(restore);
    expect(applySql).toBeGreaterThan(exactInventory);
    expect(shell).toContain("create-source-snapshot-backup.sh");
    expect(shell).toContain("source-restore-inventory.sql");
    expect(shell).toContain("inventory_sha256");
  });

  it("controleert de werkelijk actieve runtime zonder secrets te sourcen", () => {
    const lock = shell.indexOf('flock -n 9');
    const runtimeCheck = shell.indexOf(
      "assert-runtime-providers-disabled.mjs",
    );
    const containerCheck = shell.indexOf(
      'process.env[name] === "false"',
    );
    const stop = shell.indexOf("compose stop --timeout 30 scheduler app");
    expect(runtimeCheck).toBeGreaterThan(lock);
    expect(containerCheck).toBeGreaterThan(runtimeCheck);
    expect(stop).toBeGreaterThan(containerCheck);
    expect(shell).toContain('stat -c \'%a\' "${runtime_env_file}"');
    expect(shell).toContain('-O "${runtime_env_file}"');
    expect(shell).not.toContain("source \"${runtime_env_file}\"");
  });

  it("uploadt de herstelgeteste backup duurzaam vóór de applyfase", () => {
    const prepare = workflow.indexOf("CLEANUP_PHASE: prepare");
    const upload = workflow.indexOf("id: backup-upload");
    const redownload = workflow.indexOf(
      "Re-download and byte-verify the durable backup artifact",
    );
    const applyPhase = workflow.indexOf("CLEANUP_PHASE: apply");
    expect(prepare).toBeGreaterThan(0);
    expect(upload).toBeGreaterThan(prepare);
    expect(redownload).toBeGreaterThan(upload);
    expect(applyPhase).toBeGreaterThan(redownload);
    expect(workflow).toContain("BACKUP_ARTIFACT_ID: ${{ steps.backup-upload.outputs.artifact-id }}");
    expect(workflow).toContain(".prepared.json");
    expect(workflow).toContain("actions/artifacts/${BACKUP_ARTIFACT_ID}/zip");
    expect(workflow).toContain("cmp --silent");
    expect(workflow).toContain(
      "staging-cleanup-redownload-${{ github.run_id }}-${{ github.run_attempt }}",
    );
  });

  it("draait dry-run en apply alleen op de stagingrunner en serialiseert met deploy", () => {
    expect(workflow).toContain("group: deploy-duindorpteneu-staging");
    expect(workflow.match(/- duindorpteneu/g)).toHaveLength(2);
    expect(workflow.match(/- staging/g)).toHaveLength(2);
    expect(workflow.match(/- deploy/g)).toHaveLength(2);
    expect(workflow).not.toContain("runs-on: ubuntu-latest");
    expect(workflow).toContain("STAGING_CLEANUP_BACKUP_PASSPHRASE");
    expect(workflow).toContain("ref: ${{ needs.preflight.outputs.release_sha }}");
    expect(workflow).not.toContain("production");
  });
});
