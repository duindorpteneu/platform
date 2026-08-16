import { describe, expect, it } from "vitest";
// @ts-expect-error The workflow entrypoint is intentionally plain Node.js ESM.
import { buildCleanupEvidence } from "./write-cleanup-evidence.mjs";

const rowCounts = Object.fromEntries(
  Array.from({ length: 101 }, (_, index) => [`app.cleanup_${String(index).padStart(3, "0")}`, index]),
);
const blockers = {
  active_import_leases: 0,
  active_scan_grants: 0,
  database_email_enabled: 0,
  database_mollie_enabled: 0,
  inflight_email_jobs: 0,
  open_provider_payments: 0,
};
const preserved = {
  active_admins: 1,
  auth_users: 3,
  mail_templates: 19,
  seasons: 1,
  staff_profiles: 3,
  supplier_principals: 1,
};
const totalRows = Object.values(rowCounts).reduce((sum, count) => sum + count, 0);
const preflight = {
  schema_version: 1,
  mode: "dry-run",
  latest_migration_version: "20260802280000",
  state_digest: "a".repeat(64),
  cleanup_table_count: 101,
  preserved_table_count: 28,
  total_rows: totalRows,
  non_empty_tables: 89,
  row_counts: rowCounts,
  blockers,
  preserved,
};
const values = {
  CLEANUP_MODE: "dry-run",
  RELEASE_SHA: "b".repeat(40),
  SUPABASE_PROJECT_REF: "dxbdjtbyghsovlrdcwcr",
  STARTED_AT: "2026-08-03T19:00:00Z",
  COMPLETED_AT: "2026-08-03T19:01:00Z",
};

describe("buildCleanupEvidence", () => {
  it("maakt PII-vrij dry-runbewijs zonder de interne statedigest", () => {
    const evidence = buildCleanupEvidence(preflight, null, values);
    expect(evidence).toMatchObject({
      result: "dry-run",
      release_sha: values.RELEASE_SHA,
      mutation: null,
      backup: null,
    });
    expect(JSON.stringify(evidence)).not.toContain(preflight.state_digest);
    expect(JSON.stringify(evidence)).not.toContain(values.SUPABASE_PROJECT_REF);
  });

  it("vereist bij apply een versleuteld en hersteld backupbewijs plus exacte postcondities", () => {
    const applyValues = {
      ...values,
      CLEANUP_MODE: "apply",
      CLEANUP_RUN_ID: "019fc2c0-77e0-7e01-85b3-37e1f29a1a31",
      BACKUP_CHECKSUM: "c".repeat(64),
      BACKUP_ARTIFACT_NAME: "staging-domain-backup-019fc2c0-77e0-7e01-85b3-37e1f29a1a31",
      BACKUP_ARTIFACT_ID: "123456",
      EXACT_RESTORE_PROVEN: "true",
      RUNTIME_RECOVERY_PROVEN: "true",
    };
    const evidence = buildCleanupEvidence(preflight, {
      schema_version: 1,
      result: "committed",
      cleanup_run_id: applyValues.CLEANUP_RUN_ID,
      cleanup_table_count: 101,
      removed_rows: totalRows,
      remaining_operational_rows: 0,
      cleanup_audit_rows: 1,
      preserved,
    }, applyValues);
    expect(evidence).toMatchObject({
      result: "passed",
      mutation: { remaining_operational_rows: 0, cleanup_audit_rows: 1 },
      backup: {
        artifact_id: "123456",
        encrypted: true,
        decrypted_restore_verified: true,
        restore_network: "none",
      },
      exact_restore: {
        data_hmac_exact: true,
        identity_hmac_exact: true,
        inventory_proven: true,
        owner_acl_rls_exact: true,
        role_contract_exact: true,
        schema_definition_exact: true,
      },
      runtime_recovery: {
        app_health_proven: true,
        scheduler_health_proven: true,
      },
    });
    expect(buildCleanupEvidence(preflight, {
      schema_version: 1,
      result: "committed",
      cleanup_run_id: applyValues.CLEANUP_RUN_ID,
      cleanup_table_count: 101,
      removed_rows: totalRows,
      remaining_operational_rows: 0,
      cleanup_audit_rows: 1,
      preserved,
    }, {
      ...applyValues,
      RUNTIME_RECOVERY_PROVEN: "false",
    })).toMatchObject({
      result: "committed",
      runtime_recovery: {
        app_health_proven: false,
        scheduler_health_proven: false,
      },
    });
    expect(() => buildCleanupEvidence(preflight, {
      schema_version: 1,
      result: "committed",
      cleanup_run_id: applyValues.CLEANUP_RUN_ID,
      cleanup_table_count: 101,
      removed_rows: totalRows,
      remaining_operational_rows: 0,
      cleanup_audit_rows: 1,
      preserved,
    }, {
      ...applyValues,
      EXACT_RESTORE_PROVEN: "false",
    })).toThrow("Exact bron-/restorebewijs ontbreekt");
  });

  it.each([
    [{ ...preflight, cleanup_table_count: 89 }, null, values],
    [{ ...preflight, blockers: { ...blockers, open_provider_payments: "mail@example.nl" } }, null, values],
    [{ ...preflight, row_counts: { ...rowCounts, "app.extra": 1 } }, null, values],
    [preflight, { schema_version: 1, result: "committed" }, { ...values, CLEANUP_MODE: "apply" }],
  ])("weigert incompleet, onverwacht of niet-geaggregeerd bewijs", (candidatePreflight, post, candidateValues) => {
    expect(() => buildCleanupEvidence(candidatePreflight, post, candidateValues)).toThrow();
  });
});
