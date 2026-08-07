import { readdir } from "node:fs/promises";
import path from "node:path";
import { describe, expect, it } from "vitest";
// @ts-expect-error Deployment helper is intentionally plain ESM.
import { validateSourceRestoreInventory } from "./validate-source-restore-inventory.mjs";

function inventory(migrations: string[]) {
  return {
    contractVersion: 2,
    postgresMajor: 17,
    migrations,
    schemas: [{ name: "app", owner: "postgres", acl: [] }],
    relations: [{
      identity: "app.members",
      kind: "r",
      owner: "postgres",
      rowCount: 2,
      rowHmac: "c".repeat(64),
      rls: true,
      forceRls: false,
      acl: [],
    }],
    columns: [{
      identity: "app.members.id",
      position: 1,
      type: "uuid",
    }],
    types: [{
      identity: "app.members",
      enumLabels: [],
    }],
    views: [],
    sequences: [],
    constraints: [],
    indexes: [],
    policies: [],
    functions: [],
    triggers: [],
    defaultAcls: [],
    roles: Array.from({ length: 12 }, (_, index) => ({
      name: `role-${index}`,
      superuser: false,
      bypassRls: false,
      memberships: [],
    })),
    identities: {
      authUserCount: 1,
      authUserIdHmac: "a".repeat(64),
      staffCount: 1,
      adminCount: 1,
      staffIdHmac: "b".repeat(64),
    },
    security: {
      underlyingMemberRows: 2,
      unauthorizedMemberRows: 0,
      unauthorizedAccessDenied: true,
    },
  };
}

describe("source/restore inventory", () => {
  it("accepteert een exacte huidige restore", async () => {
    const current = inventory((await readdir(
      path.join(process.cwd(), "supabase/migrations"),
    ))
      .filter((name) => /^\d{14}_.+\.sql$/u.test(name))
      .map((name) => name.slice(0, 14))
      .sort());
    await expect(validateSourceRestoreInventory({
      source: current,
      restored: structuredClone(current),
      mode: "current",
      repositoryRoot: process.cwd(),
    })).resolves.toMatchObject({
      result: "passed",
      contract_mode: "current",
      owner_acl_rls_exact: true,
      data_hmac_exact: true,
      schema_definition_exact: true,
    });
  });

  it("weigert datadrift, ACL-drift en identiteitsdrift", async () => {
    const source = inventory(["20260718000100"]);
    for (const restored of [
      {
        ...structuredClone(source),
        relations: [{ ...source.relations[0], rowCount: 1 }],
      },
      {
        ...structuredClone(source),
        relations: [{
          ...source.relations[0],
          rowHmac: "d".repeat(64),
        }],
      },
      {
        ...structuredClone(source),
        schemas: [{ ...source.schemas[0], owner: "supabase_admin" }],
      },
      {
        ...structuredClone(source),
        identities: {
          ...source.identities,
          authUserIdHmac: "c".repeat(64),
        },
      },
    ]) {
      await expect(validateSourceRestoreInventory({
        source,
        restored,
        mode: "source",
        repositoryRoot: process.cwd(),
      })).rejects.toThrow();
    }
  });

  it("weigert een bronmigratie die geen kandidaatprefix is", async () => {
    const source = inventory(["99999999999999"]);
    await expect(validateSourceRestoreInventory({
      source,
      restored: structuredClone(source),
      mode: "source",
      repositoryRoot: process.cwd(),
    })).rejects.toThrow("prefix");
  });
});
