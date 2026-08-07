import { describe, expect, it } from "vitest";
// @ts-expect-error The workflow entrypoint is intentionally plain Node.js ESM.
import { buildStagingAttestation, verifyStagingAttestation } from "./staging-attestation.mjs";

const expected = {
  kind: "core",
  releaseSha: "a".repeat(40),
  repository: "duindorpteneu/platform",
  runId: "12345",
  stagingDeployRunId: "23456",
  artifactDigest: `sha256:${"c".repeat(64)}`,
  resultArtifactId: "34567",
  resultArtifactDigest: `sha256:${"d".repeat(64)}`,
  resultSha256: `sha256:${"e".repeat(64)}`,
};

describe("staging attestation", () => {
  it("bindt een groen bewijs aan soort, SHA, repository en workflowrun", () => {
    const value = buildStagingAttestation({
      ...expected,
      runId: expected.runId,
      runAttempt: "2",
      createdAt: "2026-08-03T20:00:00Z",
    });
    expect(verifyStagingAttestation(value, expected)).toEqual(value);
  });

  it.each([
    { kind: "unknown" },
    { releaseSha: "short" },
    { repository: "../other" },
    { runId: "0" },
    { stagingDeployRunId: "0" },
    { artifactDigest: "sha256:short" },
    { resultSha256: "sha256:short" },
    { resultArtifactId: "0" },
    { resultArtifactDigest: "sha256:short" },
  ])("weigert een ongeldige creatieparameter", (override) => {
    expect(() => buildStagingAttestation({
      ...expected,
      runAttempt: "1",
      createdAt: "2026-08-03T20:00:00Z",
      ...override,
    })).toThrow();
  });

  it.each([
    { workflow_kind: "mollie" },
    { release_sha: "b".repeat(40) },
    { workflow_run_id: 67890 },
    { staging_deploy_run_id: 67890 },
    { artifact_digest: `sha256:${"b".repeat(64)}` },
    { result_artifact_id: 99999 },
    { result_artifact_digest: `sha256:${"b".repeat(64)}` },
    { result_sha256: `sha256:${"f".repeat(64)}` },
    { extra: "veld" },
  ])("weigert drift of een attestation voor een andere run", (override) => {
    const value = buildStagingAttestation({
      ...expected,
      runAttempt: "1",
      createdAt: "2026-08-03T20:00:00Z",
    });
    expect(() => verifyStagingAttestation({ ...value, ...override }, expected)).toThrow();
  });

  it("bindt een deployattestation aan de eigen deployrun", () => {
    expect(() => buildStagingAttestation({
      ...expected,
      kind: "deploy",
      runAttempt: "1",
      createdAt: "2026-08-03T20:00:00Z",
    })).toThrow();
    expect(buildStagingAttestation({
      ...expected,
      kind: "deploy",
      stagingDeployRunId: expected.runId,
      runAttempt: "1",
      createdAt: "2026-08-03T20:00:00Z",
    }).workflow_kind).toBe("deploy");
  });
});
