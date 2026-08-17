import { describe, expect, it } from "vitest";
// @ts-expect-error Workflow entrypoint is intentionally plain Node.js ESM.
import { buildRestoreEvidence, validateRestoreEvidence } from "./write-restore-evidence.mjs";

const raw = {
  contract_version: 2,
  result: "passed",
  contract_mode: "current",
  inventory_sha256: "d".repeat(64),
  postgres_major: 17,
  source_postgres_major: 17,
  source_migration_count: 126,
  candidate_migration_count: 126,
  relation_count: 160,
  column_count: 900,
  type_count: 200,
  view_count: 8,
  sequence_count: 12,
  function_count: 240,
  policy_count: 80,
  trigger_count: 90,
  underlying_member_rows: 0,
  unauthorized_member_rows: 0,
  unauthorized_member_access_denied: true,
  auth_user_count: 1,
  staff_count: 1,
  admin_count: 1,
  owner_acl_rls_exact: true,
  schema_definition_exact: true,
  data_hmac_exact: true,
  role_contract_exact: true,
  identity_hmac_exact: true,
};
const values = {
  RELEASE_SHA: "b".repeat(40),
  RESTORE_SOURCE_RELEASE_SHA: "b".repeat(40),
  RESTORE_SOURCE_ARTIFACT_DIGEST: `sha256:${"a".repeat(64)}`,
  SUPABASE_PROJECT_REF: "dxbdjtbyghsovlrdcwcr",
  RESTORE_TARGET_ENVIRONMENT: "staging",
  RESTORE_CONTRACT_MODE: "current",
  RESTORE_ENCRYPTED_SHA256: "",
  STARTED_AT: "2026-08-07T10:00:00Z",
  BACKUP_SNAPSHOT_AT: "2026-08-07T10:00:00Z",
  COMPLETED_AT: "2026-08-07T10:05:00Z",
  BACKUP_SNAPSHOT_AGE_SECONDS: "300",
  RESTORE_DURATION_SECONDS: "300",
};

describe("buildRestoreEvidence", () => {
  it("maakt uitsluitend geredigeerd bron-restorebewijs", () => {
    const evidence = buildRestoreEvidence(raw, values);
    expect(evidence).toMatchObject({
      result: "passed",
      release_sha: values.RELEASE_SHA,
      schema_version: 5,
      database: {
        source_postgres_major: 17,
        contract_mode: "current",
        candidate_contract_exact: true,
        inventory_sha256: "d".repeat(64),
        owner_acl_rls_exact: true,
        schema_definition_exact: true,
        data_content_hmac_exact: true,
        role_contract_exact: true,
        security_contract: {
          source_adaptive_rls: true,
          underlying_member_rows: 0,
          unauthorized_member_rows: 0,
          unauthorized_access_denied: true,
        },
      },
      isolation: {
        source_and_dump_same_exported_snapshot: true,
        target_network: "none",
        plaintext_dump_uploaded: false,
        raw_inventory_uploaded: false,
      },
    });
    expect(JSON.stringify(evidence))
      .not.toContain(values.SUPABASE_PROJECT_REF);
    expect(validateRestoreEvidence(evidence, {
      releaseSha: values.RELEASE_SHA,
      artifactDigest: values.RESTORE_SOURCE_ARTIFACT_DIGEST,
      targetEnvironment: "staging",
    })).toEqual(evidence);
  });

  it("bindt een productieherstelpunt aan een oudere bronprefix", () => {
    const evidence = buildRestoreEvidence({
      ...raw,
      contract_mode: "source",
      source_postgres_major: 15,
      source_migration_count: 59,
    }, {
      ...values,
      SUPABASE_PROJECT_REF: "wobcbufmmputydtzemyu",
      RESTORE_TARGET_ENVIRONMENT: "production",
      RESTORE_CONTRACT_MODE: "source",
      RESTORE_ENCRYPTED_SHA256: "c".repeat(64),
    });
    expect(evidence).toMatchObject({
      target: "production-logical-backup-isolated-restore",
      database: {
        contract_mode: "source",
        candidate_contract_exact: false,
        source_postgres_major: 15,
        source_migration_count: 59,
        candidate_migration_count: 126,
      },
      encrypted_backup: {
        algorithm: "AES256",
        sha256: "c".repeat(64),
      },
    });
  });

  it.each([
    [{ ...raw, owner_acl_rls_exact: false }, values],
    [{ ...raw, unauthorized_member_rows: 1 }, values],
    [{
      ...raw,
      source_migration_count: 125,
    }, values],
    [raw, { ...values, BACKUP_SNAPSHOT_AGE_SECONDS: "86401" }],
    [raw, { ...values, RESTORE_DURATION_SECONDS: "14401" }],
    [raw, {
      ...values,
      BACKUP_SNAPSHOT_AT: "2026-08-07T09:59:59Z",
    }],
    [raw, {
      ...values,
      SUPABASE_PROJECT_REF: "wobcbufmmputydtzemyu",
      RESTORE_TARGET_ENVIRONMENT: "production",
      RESTORE_CONTRACT_MODE: "source",
      RESTORE_ENCRYPTED_SHA256: "",
    }],
  ])("weigert onjuist of niet-gebonden bewijs", (
    candidateRaw,
    candidateValues,
  ) => {
    expect(() => buildRestoreEvidence(candidateRaw, candidateValues))
      .toThrow();
  });

  it.each([
    { result: "failed" },
    { release_sha: "c".repeat(40) },
    { source_release: { release_sha: values.RELEASE_SHA } },
    { objectives: { managed_backup_rpo_proven: false } },
    { database: { owner_acl_rls_exact: true } },
    { extra: true },
  ])("weigert drift in gepubliceerd restorebewijs", (override) => {
    const evidence = buildRestoreEvidence(raw, values);
    expect(() => validateRestoreEvidence({
      ...evidence,
      ...override,
    }, {
      releaseSha: values.RELEASE_SHA,
      artifactDigest: values.RESTORE_SOURCE_ARTIFACT_DIGEST,
      targetEnvironment: "staging",
    })).toThrow();
  });
});
