import { readdir } from "node:fs/promises";
import path from "node:path";
import { describe, expect, it } from "vitest";
// @ts-expect-error Deployment helper is intentionally plain ESM.
import * as restoreInventory from "./validate-source-restore-inventory.mjs";

const {
  sourceHasPostgresRealtimeAdminMembership,
  sourceHasSupabaseFunctionsAdmin,
  validateSourceRestoreInventory,
} = restoreInventory;

const requiredRoleNames = [
  "anon",
  "authenticated",
  "authenticator",
  "dashboard_user",
  "postgres",
  "service_role",
  "supabase_admin",
  "supabase_auth_admin",
  "supabase_read_only_user",
  "supabase_replication_admin",
  "supabase_storage_admin",
];

const requiredMemberships = new Map([
  ["authenticator", ["anon", "authenticated", "service_role"]],
  ["postgres", [
    "anon",
    "authenticated",
    "authenticator",
    "pg_create_subscription",
    "pg_monitor",
    "pg_read_all_data",
    "pg_signal_backend",
    "service_role",
    "supabase_privileged_role",
  ]],
  ["supabase_read_only_user", ["pg_monitor", "pg_read_all_data"]],
  ["supabase_storage_admin", ["authenticator"]],
]);

function role(name: string, memberships = requiredMemberships.get(name) ?? []) {
  return {
    name,
    superuser: false,
    inherit: true,
    createRole: false,
    createDatabase: false,
    login: false,
    replication: false,
    bypassRls: false,
    connectionLimit: -1,
    memberships,
  };
}

function inventory(
  migrations: string[],
  includeSupabaseFunctionsAdmin = false,
  includePostgresRealtimeAdminMembership = false,
  postgresMajor = 17,
) {
  const postgresMemberships = [
    ...(requiredMemberships.get("postgres") ?? []),
    ...(includeSupabaseFunctionsAdmin ? ["supabase_functions_admin"] : []),
    ...(includePostgresRealtimeAdminMembership
      ? ["supabase_realtime_admin"]
      : []),
  ].sort();
  return {
    contractVersion: 2,
    postgresMajor,
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
    roles: [
      ...requiredRoleNames.map((name) =>
        role(name, name === "postgres" ? postgresMemberships : undefined)),
      ...(includeSupabaseFunctionsAdmin
        ? [role("supabase_functions_admin")]
        : []),
    ],
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
  it.each([
    [false, false],
    [false, true],
    [true, false],
    [true, true],
  ])(
    "accepteert exact met Functions-rol=%s en realtime-membership=%s",
    async (
      includeSupabaseFunctionsAdmin,
      includePostgresRealtimeAdminMembership,
    ) => {
      const current = inventory((await readdir(
        path.join(process.cwd(), "supabase/migrations"),
      ))
        .filter((name) => /^\d{14}_.+\.sql$/u.test(name))
        .map((name) => name.slice(0, 14))
        .sort(),
      includeSupabaseFunctionsAdmin,
      includePostgresRealtimeAdminMembership);
      expect(sourceHasSupabaseFunctionsAdmin(current))
        .toBe(includeSupabaseFunctionsAdmin);
      expect(sourceHasPostgresRealtimeAdminMembership(current))
        .toBe(includePostgresRealtimeAdminMembership);
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
    },
  );

  it("herstelt een ondersteunde legacybron exact naar PostgreSQL 17", async () => {
    const migrations = ["20260718000100"];
    const source = inventory(migrations, false, false, 15);
    const restored = inventory(migrations);
    await expect(validateSourceRestoreInventory({
      source,
      restored,
      mode: "source",
      repositoryRoot: process.cwd(),
    })).resolves.toMatchObject({
      result: "passed",
      source_postgres_major: 15,
      postgres_major: 17,
      schema_definition_exact: true,
      data_hmac_exact: true,
    });
  });

  it.each([14, 18])("weigert bronmajor %s", async (postgresMajor) => {
    const source = inventory(["20260718000100"], false, false, postgresMajor);
    await expect(validateSourceRestoreInventory({
      source,
      restored: inventory(["20260718000100"]),
      mode: "source",
      repositoryRoot: process.cwd(),
    })).rejects.toThrow("ongeldig contract");
  });

  it("houdt stagingbron en hersteldoel strikt op PostgreSQL 17", async () => {
    const source = inventory(["20260718000100"], false, false, 15);
    await expect(validateSourceRestoreInventory({
      source,
      restored: inventory(["20260718000100"]),
      mode: "current",
      repositoryRoot: process.cwd(),
    })).rejects.toThrow("ongeldig contract");
  });

  it.each([
    ["ontbrekende kernrol", (roles: ReturnType<typeof role>[]) =>
      roles.filter(({ name }) => name !== "authenticated")],
    ["onbekende rol", (roles: ReturnType<typeof role>[]) => [
      ...roles,
      role("onbekend"),
    ]],
    ["dubbele rol", (roles: ReturnType<typeof role>[]) => [
      ...roles,
      role("authenticated"),
    ]],
    ["onbekend lidmaatschap", (roles: ReturnType<typeof role>[]) =>
      roles.map((item) => item.name === "postgres"
        ? { ...item, memberships: [...item.memberships, "onbekend"] }
        : item)],
    ["bekend lidmaatschap op verkeerde rol", (
      roles: ReturnType<typeof role>[],
    ) => roles.map((item) => item.name === "authenticated"
      ? { ...item, memberships: ["pg_monitor"] }
      : item)],
    ["dubbel lidmaatschap", (roles: ReturnType<typeof role>[]) =>
      roles.map((item) => item.name === "postgres"
        ? { ...item, memberships: [...item.memberships, "pg_monitor"] }
        : item)],
    ["ontbrekend kernlidmaatschap", (roles: ReturnType<typeof role>[]) =>
      roles.map((item) => item.name === "postgres"
        ? {
            ...item,
            memberships: item.memberships.filter((name) =>
              name !== "pg_monitor"),
          }
        : item)],
  ])("weigert een %s", async (_label, mutateRoles) => {
    const source = inventory(["20260718000100"]);
    source.roles = mutateRoles(source.roles);
    expect(() => sourceHasSupabaseFunctionsAdmin(source)).toThrow(
      "ongeldig contract",
    );
    await expect(validateSourceRestoreInventory({
      source,
      restored: structuredClone(source),
      mode: "source",
      repositoryRoot: process.cwd(),
    })).rejects.toThrow("ongeldig contract");
  });

  it("weigert een Functions-rol zonder exact postgres-lidmaatschap", () => {
    const source = inventory(["20260718000100"], true);
    const postgres = source.roles.find(({ name }) => name === "postgres");
    if (!postgres) throw new Error("postgres-testrol ontbreekt");
    postgres.memberships = postgres.memberships.filter((membership) =>
      membership !== "supabase_functions_admin");
    expect(() => sourceHasSupabaseFunctionsAdmin(source)).toThrow(
      "ongeldig contract",
    );
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

  it("weigert exact de concrete postgres-membershiprestoredrift", async () => {
    const source = inventory(["20260718000100"], false, false);
    const restored = inventory(["20260718000100"], false, true);
    await expect(validateSourceRestoreInventory({
      source,
      restored,
      mode: "source",
      repositoryRoot: process.cwd(),
    })).rejects.toThrow("postgres:memberships");
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
