import { describe, expect, it } from "vitest";
// @ts-expect-error Workflow entrypoint is intentionally plain Node.js ESM.
import { buildStagingResult, sha256Bytes, verifyStagingResult } from "./staging-result.mjs";

const expected = {
  kind: "phase-b",
  releaseSha: "a".repeat(40),
  repository: "duindorpteneu/platform",
  runId: "12345",
  stagingDeployRunId: "23456",
  artifactDigest: `sha256:${"c".repeat(64)}`,
};

describe("staging result", () => {
  it("bindt alle verplichte checks canoniek aan release en run", () => {
    const value = buildStagingResult({
      ...expected,
      runAttempt: "2",
      createdAt: "2026-08-07T20:00:00Z",
    });
    expect(verifyStagingResult(value, expected)).toEqual(value);
    expect(Object.keys(value.checks)).toContain("capacity_contract");
    expect(Object.values(value.checks).every(Boolean)).toBe(true);
  });

  it("bindt restore, rollback en SendGrid verplicht aan inhoudelijk bewijs", () => {
    expect(() => buildStagingResult({
      ...expected,
      kind: "restore",
      runAttempt: "1",
      createdAt: "2026-08-07T20:00:00Z",
    })).toThrow();
    expect(buildStagingResult({
      ...expected,
      kind: "restore",
      runAttempt: "1",
      evidenceSha256: `sha256:${"d".repeat(64)}`,
      createdAt: "2026-08-07T20:00:00Z",
    }).evidence_sha256).toBe(`sha256:${"d".repeat(64)}`);
    expect(() => buildStagingResult({
      ...expected,
      kind: "provider-sendgrid",
      runAttempt: "1",
      createdAt: "2026-08-07T20:00:00Z",
    })).toThrow();
    const sendGrid = buildStagingResult({
      ...expected,
      kind: "provider-sendgrid",
      runAttempt: "1",
      evidenceSha256: `sha256:${"e".repeat(64)}`,
      createdAt: "2026-08-07T20:00:00Z",
    });
    expect(sendGrid.checks).toMatchObject({
      post_delivery_operational_health: true,
    });
  });

  it.each([
    { result: "failed" },
    { checks: { capacity_contract: true } },
    { workflow_kind: "core" },
    { release_sha: "b".repeat(40) },
    { workflow_run_id: 999 },
    { extra: true },
  ])("weigert drift of niet-volledig bewijs", (override) => {
    const value = buildStagingResult({
      ...expected,
      runAttempt: "1",
      createdAt: "2026-08-07T20:00:00Z",
    });
    expect(() => verifyStagingResult({
      ...value,
      ...override,
    }, expected)).toThrow();
  });

  it("hashes exact de geüploade bytes", () => {
    expect(sha256Bytes(Buffer.from("bewijs\n"))).toMatch(
      /^sha256:[a-f0-9]{64}$/u,
    );
    expect(sha256Bytes(Buffer.from("bewijs\n")))
      .not.toBe(sha256Bytes(Buffer.from("bewijs")));
  });
});
