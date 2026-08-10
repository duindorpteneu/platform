import { describe, expect, it } from "vitest";
// @ts-expect-error The workflow entrypoint is intentionally plain Node.js ESM.
import { validateStagingDeployEvidence, validateStagingDeployRun, validateStagingManifest } from "./verify-staging-deploy.mjs";

const releaseSha = "a".repeat(40);
const repository = "duindorpteneu/platform";
const expected = {
  runId: 123,
  workflowId: 456,
  repository,
  releaseSha,
};
const run = {
  id: 123,
  workflow_id: 456,
  path: ".github/workflows/deploy.yml",
  head_branch: "main",
  head_sha: releaseSha,
  event: "push",
  run_attempt: 1,
  status: "completed",
  conclusion: "success",
  created_at: new Date(Date.now() - 60_000).toISOString(),
  updated_at: new Date().toISOString(),
  head_repository: { full_name: repository },
};
const jobs = {
  total_count: 3,
  jobs: [
    "Preflight and quality gates",
    "Build immutable release image",
    "Deploy and verify staging",
  ].map((name) => ({
    name,
    status: "completed",
    conclusion: "success",
  })),
};
const artifacts = {
  total_count: 4,
  artifacts: [
    `release-image-${releaseSha}`,
    `staging-release-${releaseSha}`,
    `staging-result-deploy-${run.id}-${run.run_attempt}`,
    `staging-attestation-deploy-${run.id}`,
  ].map((name, index) => ({
    id: index + 1,
    name,
    expired: false,
    digest: `sha256:${String(index + 1).repeat(64)}`,
  })),
};
const manifest = {
  schemaVersion: 2,
  gitSha: releaseSha,
  imageTag: `duindorpteneu-app:${releaseSha}`,
  imageDigest: `sha256:${"b".repeat(64)}`,
  imageConfigDigest: `sha256:${"c".repeat(64)}`,
  artifactDigest: `sha256:${"d".repeat(64)}`,
  deployedAt: "2026-08-03T20:00:00.000Z",
  environment: "staging",
};

describe("validateStagingDeployRun", () => {
  it.each(["push", "workflow_dispatch"])("accepteert een groene canonieke %s-run", (event) => {
    expect(validateStagingDeployRun({ ...run, event }, expected)).toEqual({ ...run, event });
  });

  it.each([
    { id: 999 },
    { workflow_id: 999 },
    { path: ".github/workflows/other.yml" },
    { head_branch: "feature" },
    { event: "pull_request" },
    { status: "in_progress" },
    { conclusion: "skipped" },
    { head_repository: { full_name: "other/repository" } },
    { head_sha: "b".repeat(40) },
  ])("weigert runmetadata-drift", (override) => {
    expect(() => validateStagingDeployRun({ ...run, ...override }, expected)).toThrow();
  });

  it("bindt ook een handmatige stagingdeploy rechtstreeks aan de actuele main-SHA", () => {
    expect(() => validateStagingDeployRun(
      { ...run, event: "workflow_dispatch", head_sha: "b".repeat(40) },
      expected,
    )).toThrow();
  });
});

describe("validateStagingManifest", () => {
  it("accepteert exact het stagingmanifest voor de release", () => {
    expect(validateStagingManifest(manifest, releaseSha)).toEqual(manifest);
  });

  it.each([
    { schemaVersion: 1 },
    { gitSha: "b".repeat(40) },
    { environment: "production" },
    { imageTag: "duindorpteneu-app:latest" },
    { artifactDigest: "sha256:short" },
    { extra: "veld" },
  ])("weigert manifestdrift", (override) => {
    expect(() => validateStagingManifest({ ...manifest, ...override }, releaseSha)).toThrow();
  });
});

describe("validateStagingDeployEvidence", () => {
  it("vereist alle groene jobs en exacte niet-verlopen artifacts", () => {
    expect(validateStagingDeployEvidence(
      run,
      jobs,
      artifacts,
      releaseSha,
    ).resultArtifact.name).toContain("staging-result-deploy");
  });

  it.each([
    [jobs, { ...artifacts, total_count: 5 }],
    [{
      ...jobs,
      jobs: jobs.jobs.map((job, index) => index === 0
        ? { ...job, conclusion: "failure" }
        : job),
    }, artifacts],
    [jobs, {
      ...artifacts,
      artifacts: artifacts.artifacts.map((artifact, index) => index === 2
        ? { ...artifact, digest: "sha256:short" }
        : artifact),
    }],
  ])("weigert onvolledige of niet-groene evidence", (
    candidateJobs,
    candidateArtifacts,
  ) => {
    expect(() => validateStagingDeployEvidence(
      run,
      candidateJobs,
      candidateArtifacts,
      releaseSha,
    )).toThrow();
  });
});
