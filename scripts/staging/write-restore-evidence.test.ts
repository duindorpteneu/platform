import { describe, expect, it } from "vitest";
// @ts-expect-error The workflow entrypoint is intentionally plain Node.js ESM.
import { buildRestoreEvidence } from "./write-restore-evidence.mjs";

const migrations = ["20260718000100", "20260718000200"];
const entityCounts = Object.fromEntries([
  "app.seasons", "app.staff_profiles", "app.import_batches", "app.members", "app.articles",
  "app.article_variants", "app.member_orders", "app.order_lines", "app.payments", "app.delivery_receipts",
  "app.inventory_reservations", "app.fulfilments", "app.audit_logs", "private.parent_accounts",
  "private.parent_sessions", "private.email_jobs", "private.payment_events", "private.qr_tokens",
].map((key, index) => [key, index]));

const raw = {
  postgres_major: 17,
  migration_versions: migrations,
  constraints: { check: 10, foreign_key: 20, primary_key: 18, unique: 12 },
  invalid_constraints: 0,
  rls_enabled_tables: 20,
  entity_counts: entityCounts,
};
const values = {
  RELEASE_SHA: "b".repeat(40),
  SUPABASE_PROJECT_REF: "abcdefghijklmnopqrst",
  STARTED_AT: "2026-07-21T10:00:00Z",
  BACKUP_SNAPSHOT_AT: "2026-07-21T10:00:00Z",
  COMPLETED_AT: "2026-07-21T10:05:00Z",
  RPO_SECONDS: "300",
  RTO_SECONDS: "300",
};

describe("buildRestoreEvidence", () => {
  it("maakt uitsluitend geredigeerd aggregate restorebewijs", () => {
    const evidence = buildRestoreEvidence(raw, values);
    expect(evidence).toMatchObject({
      result: "passed",
      release_sha: values.RELEASE_SHA,
      objectives: { rpo_seconds: 300, rto_seconds: 300 },
      isolation: { target_network: "none", published_ports: 0, provider_configuration: false, dump_uploaded: false },
    });
    expect(JSON.stringify(evidence)).not.toContain(values.SUPABASE_PROJECT_REF);
    expect(evidence.database.aggregate_entity_counts).toEqual(entityCounts);
  });

  it.each([
    [{ ...raw, postgres_major: 16 }, values],
    [{ ...raw, invalid_constraints: 1 }, values],
    [{ ...raw, entity_counts: { ...entityCounts, "app.members": "persoon@example.nl" } }, values],
    [raw, { ...values, RPO_SECONDS: "86401" }],
    [raw, { ...values, RTO_SECONDS: "14401" }],
  ])("weigert ongeldig of niet-geaggregeerd bewijs", (candidateRaw, candidateValues) => {
    expect(() => buildRestoreEvidence(candidateRaw, candidateValues)).toThrow();
  });
});
