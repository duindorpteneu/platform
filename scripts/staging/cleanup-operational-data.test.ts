import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const contract = readFileSync(new URL("./sql/operational-cleanup-contract.sql", import.meta.url), "utf8");
const apply = readFileSync(new URL("./sql/operational-cleanup-apply.sql", import.meta.url), "utf8");
const shell = readFileSync(new URL("./cleanup-operational-data.sh", import.meta.url), "utf8");
const restoreDrill = readFileSync(new URL("./restore-drill.sh", import.meta.url), "utf8");
const restoreRoles = readFileSync(new URL("./prepare-restore-roles.sql", import.meta.url), "utf8");
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
    expect(cleanupTables).toHaveLength(105);
    expect(new Set(cleanupTables)).toHaveLength(105);
    expect(cleanupTables).toContain("private.dynamic_import_mapping_preferences");
    expect(cleanupTables).toContain("private.member_package_bulk_requests");
    expect(cleanupTables).toContain("private.member_profile_edit_requests");
    expect(cleanupTables).toContain("private.member_size_edit_requests");
    expect(cleanupTables).toContain("private.loose_order_line_removal_requests");
    expect(contract).toContain("cardinality(pg_temp.cleanup_tables()) <> 105");
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
    const exactInventory = shell.lastIndexOf(
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
    expect(shell).toContain("--print-functions-admin-presence");
    expect(shell).toContain(
      "--print-postgres-realtime-admin-membership",
    );
    expect(shell).toContain(
      '--set=include_supabase_functions_admin="${include_supabase_functions_admin}"',
    );
    expect(shell).toContain(
      '--set=include_postgres_realtime_admin_membership="${include_postgres_realtime_admin_membership}"',
    );
    const sourceInventoryInit = restoreDrill.indexOf(
      ': > "${source_inventory_path}"',
    );
    const sourceDumpInit = restoreDrill.indexOf(
      ': > "${restore_work_dir}/source.dump"',
    );
    const snapshotContainer = restoreDrill.indexOf(
      "create-source-snapshot-backup.sh",
    );
    expect(sourceInventoryInit).toBeGreaterThan(0);
    expect(sourceDumpInit).toBeGreaterThan(sourceInventoryInit);
    expect(snapshotContainer).toBeGreaterThan(sourceDumpInit);
    expect(restoreDrill).toContain(
      'chmod 0600 "${source_inventory_path}" "${restore_work_dir}/source.dump"',
    );
  });

  it("spiegelt de optionele Functions-herstelrol vanuit de gevalideerde bron", () => {
    expect(restoreRoles).toContain(
      "\\if :{?include_supabase_functions_admin}",
    );
    expect(restoreRoles).toContain(
      "raise exception 'include_supabase_functions_admin ontbreekt'",
    );
    expect(restoreRoles).not.toContain("\\quit");
    expect(restoreRoles.match(
      /\\if :include_supabase_functions_admin/gu,
    )).toHaveLength(3);
    expect(restoreRoles).not.toMatch(
      /service_role,\n\s+supabase_functions_admin,/u,
    );
    for (const runner of [shell, restoreDrill]) {
      const derive = runner.indexOf("--print-functions-admin-presence");
      const prepare = runner.indexOf(
        '--set=include_supabase_functions_admin="${include_supabase_functions_admin}"',
      );
      expect(derive).toBeGreaterThan(0);
      expect(prepare).toBeGreaterThan(derive);
    }
  });

  it("spiegelt het optionele postgres/realtime-lidmaatschap exact", () => {
    expect(restoreRoles).toContain(
      "\\if :{?include_postgres_realtime_admin_membership}",
    );
    expect(restoreRoles).toContain(
      "raise exception 'include_postgres_realtime_admin_membership ontbreekt'",
    );
    expect(restoreRoles).toContain(
      "\\if :include_postgres_realtime_admin_membership",
    );
    expect(restoreRoles).not.toMatch(
      /supabase_privileged_role,\n\s+supabase_realtime_admin/u,
    );
    expect(restoreRoles.match(
      /grant supabase_realtime_admin to postgres;/gu,
    )).toHaveLength(1);
    const conditional = restoreRoles.indexOf(
      "\\if :include_postgres_realtime_admin_membership",
    );
    const grant = restoreRoles.indexOf(
      "grant supabase_realtime_admin to postgres;",
    );
    const conditionalEnd = restoreRoles.indexOf("\\endif", conditional);
    expect(grant).toBeGreaterThan(conditional);
    expect(grant).toBeLessThan(conditionalEnd);
    for (const runner of [shell, restoreDrill]) {
      const derive = runner.indexOf(
        "--print-postgres-realtime-admin-membership",
      );
      const prepare = runner.indexOf(
        '--set=include_postgres_realtime_admin_membership="${include_postgres_realtime_admin_membership}"',
      );
      expect(derive).toBeGreaterThan(0);
      expect(prepare).toBeGreaterThan(derive);
    }
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
      "Re-download durable backup by immutable artifact ID",
    );
    const byteVerify = workflow.indexOf(
      "Byte-verify the re-downloaded durable backup artifact",
    );
    const applyPhase = workflow.indexOf("CLEANUP_PHASE: apply");
    expect(prepare).toBeGreaterThan(0);
    expect(upload).toBeGreaterThan(prepare);
    expect(redownload).toBeGreaterThan(upload);
    expect(byteVerify).toBeGreaterThan(redownload);
    expect(applyPhase).toBeGreaterThan(byteVerify);
    expect(workflow).toContain("BACKUP_ARTIFACT_ID: ${{ steps.backup-upload.outputs.artifact-id }}");
    expect(workflow).toContain(".prepared.json");
    expect(workflow).toContain(
      "actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093",
    );
    expect(workflow).toContain(
      "artifact-ids: ${{ steps.backup-upload.outputs.artifact-id }}",
    );
    expect(workflow).toContain("merge-multiple: true");
    const redownloadBlock = workflow.slice(byteVerify, applyPhase);
    const inventory = redownloadBlock.indexOf(
      'find "${download_directory}" -mindepth 1 -maxdepth 1',
    );
    const hash = redownloadBlock.indexOf('sha256sum "${downloaded_backup}"');
    const compare = redownloadBlock.indexOf("cmp --silent");
    expect(inventory).toBeGreaterThan(0);
    expect(hash).toBeGreaterThan(inventory);
    expect(compare).toBeGreaterThan(hash);
    expect(redownloadBlock).toContain(
      "printf 'artifact_directory=%s\\n' \"${download_directory}\" >> \"${GITHUB_OUTPUT}\"",
    );
    expect(redownloadBlock).not.toContain("command -v gh");
    expect(redownloadBlock).not.toContain("command -v unzip");
    expect(workflow).toContain("cmp --silent");
    expect(workflow).toContain("steps.backup-verification.outputs.artifact_directory");
  });

  it("accepteert alleen de exact teruggelezen backup en prepared state", () => {
    const start = workflow.indexOf(
      '          download_directory="${RUNNER_TEMP}/staging-cleanup-redownload-',
    );
    const end = workflow.indexOf(
      "\n\n      - name: Recheck backup-bound state",
      start,
    );
    const verificationBlock = workflow
      .slice(start, end)
      .split("\n")
      .map((line) => line.replace(/^ {10}/u, ""))
      .join("\n");
    expect(start).toBeGreaterThan(0);
    expect(end).toBeGreaterThan(start);

    const runVerificationBlock = (
      responseMode: "valid" | "extra" | "mismatch" | "state-mismatch",
    ) => spawnSync(
      "bash",
      ["-c", `
        set -Eeuo pipefail
        test_directory="$(mktemp -d "\${TMPDIR}/cleanup-artifact-\${BASHPID}.XXXXXX")"
        trap 'rm -rf -- "\${test_directory}"' EXIT
        RUNNER_TEMP="\${test_directory}"
        GITHUB_OUTPUT="\${test_directory}/github-output"
        GITHUB_RUN_ID=123
        GITHUB_RUN_ATTEMPT=1
        BACKUP_ARTIFACT_ID=123
        BACKUP_ARTIFACT_NAME=staging-test-backup
        printf 'source-backup' > "\${RUNNER_TEMP}/\${BACKUP_ARTIFACT_NAME}.dump.gpg"
        printf 'source-state' > "\${RUNNER_TEMP}/\${BACKUP_ARTIFACT_NAME}.prepared.json"
        downloaded_directory="\${RUNNER_TEMP}/staging-cleanup-redownload-\${GITHUB_RUN_ID}-\${GITHUB_RUN_ATTEMPT}"
        mkdir -p "\${downloaded_directory}"
        if [[ "\${RESPONSE_MODE}" == "mismatch" ]]; then
          printf 'mismatched-backup' > "\${downloaded_directory}/\${BACKUP_ARTIFACT_NAME}.dump.gpg"
        else
          printf 'source-backup' > "\${downloaded_directory}/\${BACKUP_ARTIFACT_NAME}.dump.gpg"
        fi
        if [[ "\${RESPONSE_MODE}" == "state-mismatch" ]]; then
          printf 'mismatched-state' > "\${downloaded_directory}/\${BACKUP_ARTIFACT_NAME}.prepared.json"
        else
          printf 'source-state' > "\${downloaded_directory}/\${BACKUP_ARTIFACT_NAME}.prepared.json"
        fi
        if [[ "\${RESPONSE_MODE}" == "extra" ]]; then
          printf 'unexpected' > "\${downloaded_directory}/unexpected.txt"
        fi
        ${verificationBlock}
        accepted_output="$(sed -n 's/^artifact_directory=//p' "\${GITHUB_OUTPUT}")"
        [[ "\${accepted_output}" == "\${downloaded_directory}" ]]
        [[ -f "\${accepted_output}/\${BACKUP_ARTIFACT_NAME}.dump.gpg" ]]
        [[ -f "\${accepted_output}/\${BACKUP_ARTIFACT_NAME}.prepared.json" ]]
      `],
      {
        encoding: "utf8",
        env: {
          ...process.env,
          RESPONSE_MODE: responseMode,
          TMPDIR: process.env.TMPDIR ?? "/tmp",
        },
      },
    );

    expect(runVerificationBlock("valid").status).toBe(0);
    expect(runVerificationBlock("mismatch").status).not.toBe(0);
    expect(runVerificationBlock("extra").status).not.toBe(0);
    expect(runVerificationBlock("state-mismatch").status).not.toBe(0);
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

  it("installeert Node 22 en dwingt database-TLS af vóór doelvalidatie in beide runnerjobs", () => {
    const dryRun = workflow.slice(
      workflow.indexOf("  dry-run:"),
      workflow.indexOf("  apply:"),
    );
    const applyJob = workflow.slice(workflow.indexOf("  apply:"));
    for (const job of [dryRun, applyJob]) {
      const boundary = job.indexOf("bash scripts/deploy/assert-runner-boundary.sh staging");
      const setup = job.indexOf(
        "uses: actions/setup-node@820762786026740c76f36085b0efc47a31fe5020",
      );
      const tls = job.indexOf("node scripts/staging/require-database-tls.mjs");
      const nodeCall = job.indexOf("node scripts/staging/validate-target.mjs");
      expect(boundary).toBeGreaterThan(0);
      expect(setup).toBeGreaterThan(boundary);
      expect(job.slice(setup, tls)).toContain("node-version: 22");
      expect(tls).toBeGreaterThan(setup);
      expect(nodeCall).toBeGreaterThan(tls);
    }
    expect(workflow.match(/SUPABASE_DB_URL: \$\{\{ secrets\.SUPABASE_DB_URL \}\}/gu))
      .toHaveLength(2);
  });
});
