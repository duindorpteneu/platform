import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { verifyStagingAttestation } from "./staging-attestation.mjs";
import { verifyStagingResult } from "./staging-result.mjs";

const DEPLOY_WORKFLOW_PATH = ".github/workflows/deploy.yml";

function required(values, name) {
  const value = values[name]?.trim();
  if (!value) throw new Error(`${name} ontbreekt`);
  return value;
}

function positiveInteger(value) {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
}

function validSha(value) {
  return typeof value === "string" && /^[a-f0-9]{40}$/u.test(value);
}

function validDigest(value) {
  return typeof value === "string" && /^sha256:[a-f0-9]{64}$/u.test(value);
}

export function validateStagingDeployRun(run, expected) {
  if (!run
    || run.id !== expected.runId
    || run.workflow_id !== expected.workflowId
    || run.path !== DEPLOY_WORKFLOW_PATH
    || run.head_branch !== "main"
    || !["push", "workflow_dispatch"].includes(run.event)
    || run.status !== "completed"
    || run.conclusion !== "success"
    || !Number.isSafeInteger(run.run_attempt)
    || run.run_attempt < 1
    || run.head_repository?.full_name !== expected.repository
    || run.head_sha !== expected.releaseSha) {
    throw new Error("De stagingdeployrun wijkt af van het canonieke releasecontract");
  }
  return run;
}

export function validateStagingManifest(value, releaseSha) {
  const exactKeys = [
    "artifactDigest",
    "deployedAt",
    "environment",
    "gitSha",
    "imageConfigDigest",
    "imageDigest",
    "imageTag",
    "schemaVersion",
  ];
  if (!value || typeof value !== "object" || Array.isArray(value)
    || Object.keys(value).sort().some((key, index) => key !== exactKeys[index])
    || Object.keys(value).length !== exactKeys.length
    || value.schemaVersion !== 2
    || value.environment !== "staging"
    || value.gitSha !== releaseSha
    || value.imageTag !== `duindorpteneu-app:${releaseSha}`
    || !validDigest(value.imageDigest)
    || !validDigest(value.imageConfigDigest)
    || !validDigest(value.artifactDigest)
    || Number.isNaN(new Date(value.deployedAt).valueOf())) {
    throw new Error("Het stagingmanifest is ongeldig of hoort niet bij de release-SHA");
  }
  return value;
}

export function validateStagingDeployEvidence(
  run,
  jobsResponse,
  artifactsResponse,
  releaseSha,
) {
  const requiredJobs = [
    "Preflight and quality gates",
    "Build immutable release image",
    "Deploy and verify staging",
  ];
  if (
    !Array.isArray(jobsResponse?.jobs)
    || jobsResponse.total_count !== jobsResponse.jobs.length
  ) {
    throw new Error("De stagingdeployjoblijst is onvolledig");
  }
  for (const name of requiredJobs) {
    const matches = jobsResponse.jobs.filter((job) => job?.name === name);
    if (
      matches.length !== 1
      || matches[0].status !== "completed"
      || matches[0].conclusion !== "success"
    ) {
      throw new Error(`Verplichte stagingdeployjob is niet groen: ${name}`);
    }
  }
  if (
    !Array.isArray(artifactsResponse?.artifacts)
    || artifactsResponse.total_count !== artifactsResponse.artifacts.length
  ) {
    throw new Error("De stagingdeployartifactlijst is onvolledig");
  }
  const expectedNames = [
    `release-image-${releaseSha}`,
    `staging-release-${releaseSha}`,
    `staging-result-deploy-${run.id}-${run.run_attempt}`,
    `staging-attestation-deploy-${run.id}`,
  ];
  const artifacts = {};
  for (const name of expectedNames) {
    const matches = artifactsResponse.artifacts.filter(
      (artifact) => artifact?.name === name,
    );
    if (
      matches.length !== 1
      || matches[0].expired !== false
      || !Number.isSafeInteger(matches[0].id)
      || matches[0].id < 1
      || !validDigest(matches[0].digest)
    ) {
      throw new Error(`Verplicht stagingdeployartifact is ongeldig: ${name}`);
    }
    artifacts[name] = matches[0];
  }
  const createdAt = new Date(run.created_at).valueOf();
  const updatedAt = new Date(run.updated_at).valueOf();
  const now = Date.now();
  if (
    Number.isNaN(createdAt)
    || Number.isNaN(updatedAt)
    || createdAt > updatedAt
    || updatedAt > now + 5 * 60 * 1000
    || now - updatedAt > 48 * 60 * 60 * 1000
  ) {
    throw new Error("De stagingdeployrun is te oud of heeft ongeldige tijden");
  }
  return {
    resultArtifact:
      artifacts[`staging-result-deploy-${run.id}-${run.run_attempt}`],
  };
}

async function fetchJson(token, repository, path) {
  const response = await fetch(`https://api.github.com/repos/${repository}${path}`, {
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${token}`,
      "X-GitHub-Api-Version": "2022-11-28",
    },
    signal: AbortSignal.timeout(15_000),
  });
  if (!response.ok) throw new Error(`GitHub Actions API gaf HTTP ${response.status}`);
  return response.json();
}

async function main() {
  const token = required(process.env, "GITHUB_TOKEN");
  const repository = required(process.env, "GITHUB_REPOSITORY");
  const releaseSha = required(process.env, "RELEASE_SHA");
  const runId = positiveInteger(required(process.env, "STAGING_DEPLOY_RUN_ID"));
  const manifestPath = required(process.env, "STAGING_MANIFEST_PATH");
  const attestationPath = required(process.env, "STAGING_DEPLOY_ATTESTATION_PATH");
  const resultPath = required(process.env, "STAGING_DEPLOY_RESULT_PATH");
  if (!runId) throw new Error("STAGING_DEPLOY_RUN_ID is ongeldig");
  if (!validSha(releaseSha)) throw new Error("RELEASE_SHA is ongeldig");
  if (!/^[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,99})\/[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,99})$/u.test(repository)) {
    throw new Error("GITHUB_REPOSITORY is ongeldig");
  }

  const workflow = await fetchJson(token, repository, "/actions/workflows/deploy.yml");
  if (!workflow
    || !Number.isSafeInteger(workflow.id)
    || workflow.path !== DEPLOY_WORKFLOW_PATH
    || workflow.state !== "active") {
    throw new Error("Canonieke stagingdeployworkflow ontbreekt of is niet actief");
  }
  const deployRun = validateStagingDeployRun(
    await fetchJson(token, repository, `/actions/runs/${runId}`),
    { runId, workflowId: workflow.id, repository, releaseSha },
  );
  const { resultArtifact } = validateStagingDeployEvidence(
    deployRun,
    await fetchJson(
      token,
      repository,
      `/actions/runs/${runId}/jobs?filter=latest&per_page=100`,
    ),
    await fetchJson(
      token,
      repository,
      `/actions/runs/${runId}/artifacts?per_page=100`,
    ),
    releaseSha,
  );
  const manifest = validateStagingManifest(
    JSON.parse(await readFile(manifestPath, "utf8")),
    releaseSha,
  );
  const resultBytes = await readFile(resultPath);
  const resultSha256 =
    `sha256:${createHash("sha256").update(resultBytes).digest("hex")}`;
  verifyStagingResult(JSON.parse(resultBytes.toString("utf8")), {
    kind: "deploy",
    releaseSha,
    repository,
    runId,
    runAttempt: deployRun.run_attempt,
    stagingDeployRunId: runId,
    artifactDigest: manifest.artifactDigest,
  });
  verifyStagingAttestation(
    JSON.parse(await readFile(attestationPath, "utf8")),
    {
      kind: "deploy",
      releaseSha,
      repository,
      runId,
      runAttempt: deployRun.run_attempt,
      stagingDeployRunId: runId,
      artifactDigest: manifest.artifactDigest,
      resultArtifactId: resultArtifact.id,
      resultArtifactDigest: resultArtifact.digest,
      resultSha256,
    },
  );
  process.stdout.write(`${manifest.artifactDigest}\n`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : "Stagingdeploybewijs kon niet worden geverifieerd"}\n`);
    process.exitCode = 1;
  });
}
