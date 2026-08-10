import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import path from "node:path";
// @ts-expect-error The workflow entrypoint is intentionally plain Node.js ESM.
import * as promotionEvidence from "./verify-promotion-evidence.mjs";
const {
  validateArtifacts,
  validateAttestationFreshness,
  validateDeploymentBranchPolicies,
  validateProductionProtection,
  validatePromotionRun,
  validateRequiredJobs,
  validateRunFreshness,
  EVIDENCE,
} = promotionEvidence;
const repositoryRoot = path.resolve(import.meta.dirname, "../..");

const sha = "a".repeat(40);
const repository = "duindorpteneu/platform";
const expected = {
  runId: 123,
  workflowId: 456,
  workflowPath: ".github/workflows/staging-core-acceptance.yml",
  events: ["workflow_dispatch"],
  repository,
  releaseSha: sha,
};
const run = {
  id: 123,
  workflow_id: 456,
  path: expected.workflowPath,
  head_branch: "main",
  head_sha: sha,
  event: "workflow_dispatch",
  status: "completed",
  conclusion: "success",
  run_attempt: 2,
  head_repository: { full_name: repository },
  created_at: "2026-08-03T20:00:00Z",
  updated_at: "2026-08-03T20:10:00Z",
};

describe("promotion run contract", () => {
  it("accepteert de exacte groene workflowrun", () => {
    expect(validatePromotionRun(run, expected)).toEqual(run);
  });

  it.each([
    { id: 999 },
    { workflow_id: 999 },
    { path: ".github/workflows/other.yml" },
    { head_branch: "feature" },
    { event: "pull_request" },
    { status: "in_progress" },
    { conclusion: "skipped" },
    { run_attempt: 0 },
    { head_sha: "b".repeat(40) },
    { head_repository: { full_name: "other/repository" } },
  ])("weigert runmetadata-drift", (override) => {
    expect(() => validatePromotionRun({ ...run, ...override }, expected)).toThrow();
  });

  it("bindt een push-run ook rechtstreeks aan de SHA", () => {
    expect(() => validatePromotionRun(
      { ...run, event: "push", head_sha: "b".repeat(40) },
      { ...expected, events: ["push"] },
    )).toThrow();
  });
});

describe("promotion evidence freshness", () => {
  const now = new Date("2026-08-03T21:00:00Z").valueOf();

  it("accepts a recent run and an attestation created inside that run", () => {
    const window = validateRunFreshness(run, { now });
    expect(validateAttestationFreshness(
      { created_at: "2026-08-03T20:05:00Z" },
      window,
      { now },
    )).toBe(true);
  });

  it("requires acceptance to start after the deploy completed", () => {
    expect(() => validateRunFreshness(run, {
      now,
      notBefore: "2026-08-03T21:00:00Z",
    })).toThrow("vóór de stagingdeploy");
  });

  it.each([
    { created_at: "2026-07-31T20:00:00Z", updated_at: "2026-07-31T20:10:00Z" },
    { created_at: "2026-08-03T20:20:00Z", updated_at: "2026-08-03T20:10:00Z" },
    { created_at: "ongeldig" },
  ])("rejects stale or impossible run times", (override) => {
    expect(() => validateRunFreshness({ ...run, ...override }, { now })).toThrow();
  });

  it.each([
    "2026-08-03T19:00:00Z",
    "2026-08-03T21:30:00Z",
    "ongeldig",
  ])("rejects an attestation outside its run window: %s", (createdAt) => {
    expect(() => validateAttestationFreshness(
      { created_at: createdAt },
      validateRunFreshness(run, { now }),
      { now },
    )).toThrow();
  });
});

describe("promotion jobs and artifacts", () => {
  const job = { name: "Exact gate", status: "completed", conclusion: "success" };
  const artifact = {
    id: 123,
    name: "exact-artifact",
    expired: false,
    digest: `sha256:${"b".repeat(64)}`,
  };

  it("vereist iedere benoemde job exact eenmaal groen", () => {
    expect(validateRequiredJobs([job], ["Exact gate"])).toBe(true);
  });

  it.each([
    { jobs: [] },
    { jobs: [{ ...job, conclusion: "skipped" }] },
    { jobs: [job, job] },
  ])("weigert ontbrekende, overgeslagen of dubbele jobs", ({ jobs }) => {
    expect(() => validateRequiredJobs(jobs, ["Exact gate"])).toThrow();
  });

  it("vereist ieder benoemd artifact exact eenmaal, niet verlopen en met veilige identiteit", () => {
    expect(validateArtifacts([artifact], ["exact-artifact"])).toBe(true);
  });

  it.each([
    { artifacts: [] },
    { artifacts: [{ ...artifact, expired: true }] },
    { artifacts: [{ ...artifact, digest: "sha256:short" }] },
    { artifacts: [{ ...artifact, digest: undefined }] },
    { artifacts: [artifact, artifact] },
  ])("weigert ontbrekende, verlopen, ongeldige of dubbele artifacts", ({ artifacts }) => {
    expect(() => validateArtifacts(artifacts, ["exact-artifact"])).toThrow();
  });
});

describe("promotion workflow source contract", () => {
  it("keeps every required job name equal to the real workflow", () => {
    for (const contract of EVIDENCE) {
      const workflow = readFileSync(
        path.join(repositoryRoot, contract.workflowPath),
        "utf8",
      );
      for (const jobName of contract.requiredJobs) {
        expect(workflow).toContain(`name: ${jobName}`);
      }
    }
  });
});

describe("production environment protection", () => {
  const protectedEnvironment = {
    name: "production",
    deployment_branch_policy: {
      protected_branches: false,
      custom_branch_policies: true,
    },
    protection_rules: [{
      type: "required_reviewers",
      prevent_self_review: true,
      reviewers: [{ type: "User", reviewer: { id: 123, login: "release-reviewer" } }],
    }, {
      type: "branch_policy",
    }],
  };

  it("vereist een onafhankelijke reviewer en custom main-policy", () => {
    expect(validateProductionProtection(protectedEnvironment)).toBe(true);
  });

  it.each([
    { ...protectedEnvironment, protection_rules: [{ type: "branch_policy" }] },
    {
      ...protectedEnvironment,
      protection_rules: [{
        ...protectedEnvironment.protection_rules[0],
        prevent_self_review: false,
      }],
    },
    {
      ...protectedEnvironment,
      deployment_branch_policy: {
        protected_branches: false,
        custom_branch_policies: false,
      },
    },
  ])("weigert een production environment zonder technisch vier-ogenbeleid", (candidate) => {
    expect(() => validateProductionProtection(candidate)).toThrow();
  });

  it("accepteert uitsluitend de exacte main deployment branch policy", () => {
    expect(validateDeploymentBranchPolicies({
      total_count: 1,
      branch_policies: [{ id: 123, name: "main" }],
    })).toBe(true);
    expect(() => validateDeploymentBranchPolicies({
      total_count: 1,
      branch_policies: [{ id: 123, name: "*" }],
    })).toThrow();
    expect(() => validateDeploymentBranchPolicies({
      total_count: 2,
      branch_policies: [{ id: 123, name: "main" }, { id: 456, name: "release/*" }],
    })).toThrow();
  });
});
