import { describe, expect, it } from "vitest";
// @ts-expect-error The workflow entrypoint is intentionally plain Node.js ESM.
import { selectCiState, validateCiJobs, validateCiRun } from "./wait-for-ci.mjs";

const sha = "a".repeat(40);
const repository = "duindorpteneu/platform";
const workflowId = 123;
const base = {
  id: 456,
  workflow_id: workflowId,
  head_sha: sha,
  head_branch: "main",
  event: "push",
  path: ".github/workflows/ci.yml",
  head_repository: { full_name: repository },
  run_number: 12,
  run_attempt: 2,
};

describe("selectCiState", () => {
  it("selecteert de identiteit van de exacte groene push-CI", () => {
    expect(selectCiState(
      [{ ...base, status: "completed", conclusion: "success" }],
      sha,
      repository,
      workflowId,
    )).toEqual({ state: "success", runId: 456, runAttempt: 2 });
  });

  it.each([
    [{ ...base, status: "in_progress", conclusion: null }, "pending"],
    [{ ...base, status: "completed", conclusion: "failure" }, "failed"],
  ])("classificeert de exacte niet-groene push-CI", (run, state) => {
    expect(selectCiState([run], sha, repository, workflowId)).toEqual({ state });
  });

  it("negeert PR-runs, andere repositories, workflows en SHA's", () => {
    expect(selectCiState([
      { ...base, event: "pull_request", status: "completed", conclusion: "success" },
      { ...base, head_sha: "b".repeat(40), status: "completed", conclusion: "success" },
      { ...base, path: ".github/workflows/deploy.yml", status: "completed", conclusion: "success" },
      { ...base, head_repository: { full_name: "other/repository" }, status: "completed", conclusion: "success" },
      { ...base, workflow_id: 999, status: "completed", conclusion: "success" },
      { ...base, head_branch: "feature", status: "completed", conclusion: "success" },
    ], sha, repository, workflowId)).toEqual({ state: "missing" });
  });

  it("laat een nieuwere poging voorgaan boven een eerdere groene run", () => {
    expect(selectCiState([
      { ...base, id: 456, run_number: 12, status: "completed", conclusion: "success" },
      { ...base, id: 789, run_number: 13, status: "in_progress", conclusion: null },
    ], sha, repository, workflowId)).toEqual({ state: "pending" });
  });

  it("blokkeert op de nieuwere rode poging ondanks een eerdere groene run", () => {
    expect(selectCiState([
      { ...base, id: 456, run_number: 12, status: "completed", conclusion: "success" },
      { ...base, id: 789, run_number: 13, status: "completed", conclusion: "failure" },
    ], sha, repository, workflowId)).toEqual({ state: "failed" });
  });
});

describe("validateCiRun", () => {
  const expected = { runId: 456, workflowId, releaseSha: sha, repository };

  it("accepteert alleen de opnieuw opgehaalde canonieke groene run", () => {
    const run = { ...base, status: "completed", conclusion: "success" };
    expect(validateCiRun(run, expected)).toEqual(run);
  });

  it.each([
    { id: 789 },
    { workflow_id: 999 },
    { head_sha: "b".repeat(40) },
    { head_branch: "feature" },
    { event: "pull_request" },
    { path: ".github/workflows/other.yml" },
    { conclusion: "skipped" },
    { head_repository: { full_name: "other/repository" } },
  ])("weigert runmetadata-drift", (override) => {
    expect(() => validateCiRun(
      { ...base, status: "completed", conclusion: "success", ...override },
      expected,
    )).toThrow();
  });
});

describe("validateCiJobs", () => {
  const application = {
    name: "Application quality gates",
    status: "completed",
    conclusion: "success",
  };
  const database = {
    name: "Supabase migration and pgTAP gates",
    status: "completed",
    conclusion: "success",
  };

  it("vereist beide volledige jobs exact eenmaal groen", () => {
    expect(validateCiJobs([application, database])).toBe(true);
  });

  it.each([
    { jobs: [application] },
    { jobs: [application, { ...database, conclusion: "skipped" }] },
    { jobs: [application, database, database] },
    { jobs: [{ ...application, status: "in_progress" }, database] },
  ])("weigert ontbrekende, overgeslagen, dubbele of onvoltooide gates", ({ jobs }) => {
    expect(() => validateCiJobs(jobs)).toThrow();
  });
});
