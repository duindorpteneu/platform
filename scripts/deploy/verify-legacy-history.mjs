import { pathToFileURL } from "node:url";
import {
  validateDeploymentBranchPolicies,
  validateProductionProtection,
} from "./verify-promotion-evidence.mjs";
import { LEGACY_PRODUCTION_SHA } from "./legacy-health-identity.mjs";

const HISTORIC_RUN_ID = 29754524344;
const ARTIFACTS = [
  {
    id: 8466202224,
    name: `release-image-${LEGACY_PRODUCTION_SHA}`,
  },
  {
    id: 8466245309,
    name: `staging-release-${LEGACY_PRODUCTION_SHA}`,
  },
];

export function validateLegacyHistory(run, artifacts) {
  if (
    !run
    || run.id !== HISTORIC_RUN_ID
    || run.path !== ".github/workflows/deploy.yml"
    || run.head_sha !== LEGACY_PRODUCTION_SHA
    || run.head_branch !== "main"
    || run.event !== "push"
    || run.status !== "completed"
    || run.conclusion !== "success"
    || run.run_attempt !== 1
    || run.head_repository?.full_name !== "duindorpteneu/platform"
  ) throw new Error("Historische legacydeploy is niet exact bewezen");
  if (
    !Array.isArray(artifacts)
    || artifacts.length !== ARTIFACTS.length
    || ARTIFACTS.some((expected) => {
      const matches = artifacts.filter((artifact) =>
        artifact?.id === expected.id && artifact?.name === expected.name);
      return matches.length !== 1 || matches[0].expired !== true;
    })
  ) throw new Error("Historische artifacts zijn niet exact verlopen bewezen");
  return true;
}

export function validateNoPriorSuccessfulAdoption(
  runsResponse,
  currentRunId,
) {
  if (
    !Number.isSafeInteger(currentRunId)
    || currentRunId < 1
    || !runsResponse
    || !Number.isSafeInteger(runsResponse.total_count)
    || !Array.isArray(runsResponse.workflow_runs)
    || runsResponse.total_count > runsResponse.workflow_runs.length
    || runsResponse.workflow_runs.some((run) =>
      !Number.isSafeInteger(run?.id)
      || typeof run?.status !== "string"
      || !(run?.conclusion === null
        || typeof run?.conclusion === "string"))
  ) {
    throw new Error("Legacy adoptiehistorie is niet volledig bewezen");
  }
  if (runsResponse.workflow_runs.some((run) =>
    run.id !== currentRunId
    && run.status === "completed"
    && run.conclusion === "success")) {
    throw new Error("Legacy productie-adoptie is al succesvol uitgevoerd");
  }
  return true;
}

async function fetchJson(token, path) {
  const response = await fetch(
    `https://api.github.com/repos/duindorpteneu/platform${path}`,
    {
      headers: {
        Accept: "application/vnd.github+json",
        Authorization: `Bearer ${token}`,
        "X-GitHub-Api-Version": "2022-11-28",
      },
      signal: AbortSignal.timeout(15_000),
    },
  );
  if (!response.ok) throw new Error(`GitHub API gaf HTTP ${response.status}`);
  return response.json();
}

async function main() {
  const token = process.env.GITHUB_TOKEN?.trim();
  const controlSha = process.env.CONTROL_RELEASE_SHA?.trim();
  const currentRunId = Number(process.env.GITHUB_RUN_ID);
  if (
    !token
    || !/^[a-f0-9]{40}$/u.test(controlSha ?? "")
    || !Number.isSafeInteger(currentRunId)
    || currentRunId < 1
  ) {
    throw new Error("Legacy preflight mist token of actuele control-SHA");
  }
  validateProductionProtection(
    await fetchJson(token, "/environments/production"),
  );
  validateDeploymentBranchPolicies(
    await fetchJson(
      token,
      "/environments/production/deployment-branch-policies?per_page=100",
    ),
  );
  const main = await fetchJson(token, "/git/ref/heads/main");
  if (main?.object?.type !== "commit" || main.object.sha !== controlSha) {
    throw new Error("Legacy adoptie vereist exact de actuele main-controlplane");
  }
  const run = await fetchJson(token, `/actions/runs/${HISTORIC_RUN_ID}`);
  const artifacts = await fetchJson(
    token,
    `/actions/runs/${HISTORIC_RUN_ID}/artifacts?per_page=100`,
  );
  validateLegacyHistory(run, artifacts.artifacts);
  validateNoPriorSuccessfulAdoption(
    await fetchJson(
      token,
      "/actions/workflows/adopt-legacy-production.yml/runs?event=workflow_dispatch&per_page=100",
    ),
    currentRunId,
  );
  process.stdout.write(
    "Historische productie-identiteit en onafhankelijke approvalgate zijn bewezen.\n",
  );
}

if (
  process.argv[1]
  && import.meta.url === pathToFileURL(process.argv[1]).href
) {
  main().catch((error) => {
    process.stderr.write(
      `${error instanceof Error ? error.message : "Legacy historie is ongeldig"}\n`,
    );
    process.exitCode = 1;
  });
}
