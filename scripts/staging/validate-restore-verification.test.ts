import path from "node:path";
import { describe, expect, it } from "vitest";
// @ts-expect-error Plain Node.js deployment helper.
import * as restoreVerification from "./validate-restore-verification.mjs";

const {
  expectedRestoreContract,
  validateRestoreVerification,
} = restoreVerification;
const repositoryRoot = path.resolve(import.meta.dirname, "../..");

async function fixture() {
  const expected = await expectedRestoreContract(repositoryRoot);
  return {
    expected,
    raw: {
      postgres_major: 17,
      migration_versions: expected.migrationVersions,
      constraints: {
        check: 1,
        foreign_key: 1,
        primary_key: 1,
        unique: 1,
      },
      invalid_constraints: 0,
      rls_enabled_tables: 1,
      security_contract: {
        authenticated_app_usage: true,
        authenticated_staff_rpc_execute: true,
        service_role_session_rpc_execute: true,
        service_role_staff_rpc_denied: true,
        underlying_member_rows: 1,
        unauthorized_access_denied: true,
        unauthorized_member_rows: 0,
      },
      entity_counts: Object.fromEntries(
        expected.entityKeys.map((key: string) => [key, 0]),
      ),
    },
  };
}

describe("volledig restoreverificatiecontract", () => {
  it("bindt exact alle migrations en 135 app/private-tabellen", async () => {
    const { expected, raw } = await fixture();
    expect(expected.entityKeys).toHaveLength(135);
    expect(expected.entityKeys).toContain("app.member_package_assignments");
    expect(expected.entityKeys).toContain("app.member_package_size_selections");
    expect(validateRestoreVerification(raw, expected)).toBe(true);
  });

  it("rejects vacuous RLS, migration drift and schema drift", async () => {
    const { expected, raw } = await fixture();
    for (const changed of [
      {
        ...raw,
        security_contract: {
          ...raw.security_contract,
          underlying_member_rows: 0,
        },
      },
      { ...raw, migration_versions: raw.migration_versions.slice(1) },
      {
        ...raw,
        entity_counts: {
          ...raw.entity_counts,
          "app.unexpected": 0,
        },
      },
    ]) {
      expect(() => validateRestoreVerification(changed, expected))
        .toThrow("volledige contract");
    }
  });
});
