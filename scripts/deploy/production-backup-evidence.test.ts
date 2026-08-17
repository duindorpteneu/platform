import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
// @ts-expect-error JavaScript deployment helper without declaration file.
import { validateProductionBackupEvidence } from "./production-backup-evidence.mjs";

const expected = {
  candidateReleaseSha: "a".repeat(40),
  sourceReleaseSha: "b".repeat(40),
  sourceArtifactDigest: `sha256:${"c".repeat(64)}`,
  projectRef: "wobcbufmmputydtzemyu",
};

function evidence() {
  return {
    schema_version: 5,
    result: "passed",
    target: "production-logical-backup-isolated-restore",
    release_sha: expected.candidateReleaseSha,
    source_release: {
      release_sha: expected.sourceReleaseSha,
      artifact_digest: expected.sourceArtifactDigest,
    },
    source_project_fingerprint: createHash("sha256")
      .update(expected.projectRef).digest("hex").slice(0, 16),
    started_at: "2026-08-03T20:00:00.000Z",
    backup_snapshot_at: "2026-08-03T20:00:01.000Z",
    completed_at: "2026-08-03T20:05:00.000Z",
    objectives: {
      managed_backup_rpo_proven: false,
      backup_snapshot_age_seconds: 300,
      backup_snapshot_age_target_seconds: 86400,
      restore_duration_seconds: 300,
      restore_duration_target_seconds: 14400,
    },
    database: {
      postgres_major: 17,
      source_postgres_major: 15,
      contract_mode: "source",
      candidate_contract_exact: false,
      source_migration_count: 59,
      candidate_migration_count: 126,
      inventory_sha256: "e".repeat(64),
      owner_acl_rls_exact: true,
      schema_definition_exact: true,
      data_content_hmac_exact: true,
      role_contract_exact: true,
      identity_contract: {
        hmac_exact: true,
      },
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
      published_ports: 0,
      provider_configuration: false,
      plaintext_dump_uploaded: false,
      raw_inventory_uploaded: false,
    },
    encrypted_backup: {
      algorithm: "AES256",
      sha256: "d".repeat(64),
    },
  };
}

describe("production backup evidence", () => {
  it("binds restored ACL/RLS evidence to source and candidate", () => {
    expect(validateProductionBackupEvidence(evidence(), expected))
      .toBe("d".repeat(64));
  });

  it("rejects a backup from a different source artifact", () => {
    const changed = evidence();
    changed.source_release.artifact_digest = `sha256:${"e".repeat(64)}`;
    expect(() => validateProductionBackupEvidence(changed, expected))
      .toThrow("ongeldig");
  });

  it.each([
    {
      objectives: {
        ...evidence().objectives,
        managed_backup_rpo_proven: true,
      },
    },
    {
      objectives: {
        ...evidence().objectives,
        restore_duration_seconds: 14401,
      },
    },
    { completed_at: "2026-08-03T19:59:00.000Z" },
  ])("rejects false RPO claims, missed drill targets and impossible times", (override) => {
    expect(() => validateProductionBackupEvidence({
      ...evidence(),
      ...override,
    }, expected)).toThrow("ongeldig");
  });
});
