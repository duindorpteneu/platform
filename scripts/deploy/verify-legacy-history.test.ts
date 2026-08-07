import { describe, expect, it } from "vitest";
// @ts-expect-error Plain Node.js deployment helper.
import * as legacyHistory from "./verify-legacy-history.mjs";
const {
  validateLegacyHistory,
  validateNoPriorSuccessfulAdoption,
} = legacyHistory;

const sha = "a79c8d843d75e90810ccceb228538c6368d2198b";
const run = {
  id: 29754524344,
  path: ".github/workflows/deploy.yml",
  head_sha: sha,
  head_branch: "main",
  event: "push",
  status: "completed",
  conclusion: "success",
  run_attempt: 1,
  head_repository: { full_name: "duindorpteneu/platform" },
};
const artifacts = [
  {
    id: 8466202224,
    name: `release-image-${sha}`,
    expired: true,
  },
  {
    id: 8466245309,
    name: `staging-release-${sha}`,
    expired: true,
  },
];

describe("historic production deployment identity", () => {
  it("accepts only the exact successful legacy run and expired artifacts", () => {
    expect(validateLegacyHistory(run, artifacts)).toBe(true);
  });

  it.each([
    { head_sha: "b".repeat(40) },
    { conclusion: "failure" },
    { path: ".github/workflows/other.yml" },
  ])("rejects run drift", (patch) => {
    expect(() => validateLegacyHistory({ ...run, ...patch }, artifacts))
      .toThrow();
  });

  it("rejects a replacement artifact even when it has the same name", () => {
    expect(() => validateLegacyHistory(run, [
      { ...artifacts[0], id: 1, expired: false },
      artifacts[1],
    ])).toThrow();
  });

  it("allows only the current in-progress adoption run", () => {
    expect(validateNoPriorSuccessfulAdoption({
      total_count: 2,
      workflow_runs: [
        { id: 400, status: "in_progress", conclusion: null },
        { id: 399, status: "completed", conclusion: "failure" },
      ],
    }, 400)).toBe(true);
  });

  it("rejects any prior successful adoption or incomplete pagination", () => {
    expect(() => validateNoPriorSuccessfulAdoption({
      total_count: 2,
      workflow_runs: [
        { id: 400, status: "in_progress", conclusion: null },
        { id: 399, status: "completed", conclusion: "success" },
      ],
    }, 400)).toThrow("al succesvol");
    expect(() => validateNoPriorSuccessfulAdoption({
      total_count: 101,
      workflow_runs: [],
    }, 400)).toThrow("niet volledig");
  });
});
