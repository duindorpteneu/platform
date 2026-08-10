import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { verifyStagingResult } from "./staging-result.mjs";

const KINDS = new Set([
  "deploy",
  "core",
  "mollie",
  "operations",
  "phase-b",
  "restore",
  "rollback",
  "provider-sendgrid",
  "provider-mollie",
]);
const EXACT_KEYS = [
  "artifact_digest",
  "created_at",
  "release_sha",
  "repository",
  "result",
  "result_artifact_digest",
  "result_artifact_id",
  "result_sha256",
  "schema_version",
  "staging_deploy_run_id",
  "workflow_kind",
  "workflow_run_attempt",
  "workflow_run_id",
];

function validSha(value) {
  return typeof value === "string" && /^[a-f0-9]{40}$/u.test(value);
}

function validDigest(value) {
  return typeof value === "string" && /^sha256:[a-f0-9]{64}$/u.test(value);
}

function validRepository(value) {
  return typeof value === "string"
    && /^[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,99})\/[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,99})$/u.test(value);
}

function positiveInteger(value) {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
}

export function buildStagingAttestation({
  kind,
  releaseSha,
  repository,
  runId,
  runAttempt,
  stagingDeployRunId,
  artifactDigest,
  resultArtifactId,
  resultArtifactDigest,
  resultSha256,
  createdAt,
}) {
  if (!KINDS.has(kind)) throw new Error("Attestationkind is ongeldig");
  if (!validSha(releaseSha)) throw new Error("Release-SHA is ongeldig");
  if (!validDigest(artifactDigest)) throw new Error("Artefactdigest is ongeldig");
  if (!positiveInteger(resultArtifactId)) {
    throw new Error("Resultaatartifact-ID is ongeldig");
  }
  if (!validDigest(resultArtifactDigest)) {
    throw new Error("Resultaatartifactdigest is ongeldig");
  }
  if (!validDigest(resultSha256)) throw new Error("Resultaatdigest is ongeldig");
  if (!validRepository(repository)) throw new Error("Repository is ongeldig");
  const parsedRunId = positiveInteger(runId);
  const parsedAttempt = positiveInteger(runAttempt);
  const parsedDeployRunId = positiveInteger(stagingDeployRunId);
  if (!parsedRunId || !parsedAttempt || !parsedDeployRunId) {
    throw new Error("Workflow-runidentiteit is ongeldig");
  }
  if (kind === "deploy" && parsedDeployRunId !== parsedRunId) {
    throw new Error("Deployattestation moet naar de eigen workflowrun verwijzen");
  }
  const timestamp = new Date(createdAt ?? Date.now());
  if (Number.isNaN(timestamp.valueOf())) throw new Error("Attestationtijd is ongeldig");
  return {
    schema_version: 2,
    result: "passed",
    workflow_kind: kind,
    release_sha: releaseSha,
    artifact_digest: artifactDigest,
    result_artifact_id: positiveInteger(resultArtifactId),
    result_artifact_digest: resultArtifactDigest,
    result_sha256: resultSha256,
    repository,
    workflow_run_id: parsedRunId,
    workflow_run_attempt: parsedAttempt,
    staging_deploy_run_id: parsedDeployRunId,
    created_at: timestamp.toISOString(),
  };
}

export function verifyStagingAttestation(value, expected) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Attestation is ongeldig");
  const keys = Object.keys(value).sort();
  if (keys.length !== EXACT_KEYS.length || keys.some((key, index) => key !== EXACT_KEYS[index])) {
    throw new Error("Attestation bevat onverwachte velden");
  }
  const canonical = buildStagingAttestation({
    kind: value.workflow_kind,
    releaseSha: value.release_sha,
    repository: value.repository,
    runId: value.workflow_run_id,
    runAttempt: value.workflow_run_attempt,
    stagingDeployRunId: value.staging_deploy_run_id,
    artifactDigest: value.artifact_digest,
    resultArtifactId: value.result_artifact_id,
    resultArtifactDigest: value.result_artifact_digest,
    resultSha256: value.result_sha256,
    createdAt: value.created_at,
  });
  if (value.result !== "passed" || JSON.stringify(value) !== JSON.stringify(canonical)) {
    throw new Error("Attestation is niet canoniek groen");
  }
  if (canonical.workflow_kind !== expected.kind
    || canonical.release_sha !== expected.releaseSha
    || canonical.repository !== expected.repository
    || canonical.workflow_run_id !== positiveInteger(expected.runId)
    || (expected.runAttempt !== undefined
      && canonical.workflow_run_attempt !== positiveInteger(expected.runAttempt))
    || canonical.staging_deploy_run_id !== positiveInteger(expected.stagingDeployRunId)
    || canonical.artifact_digest !== expected.artifactDigest
    || canonical.result_artifact_id
      !== positiveInteger(expected.resultArtifactId)
    || canonical.result_artifact_digest
      !== expected.resultArtifactDigest) {
    throw new Error("Attestation hoort niet bij de gevraagde release-run");
  }
  if (
    expected.resultSha256 !== undefined
    && canonical.result_sha256 !== expected.resultSha256
  ) {
    throw new Error("Attestation hoort niet bij de gevraagde release-run");
  }
  return canonical;
}

async function main() {
  const [
    command,
    filePath,
    resultPath,
    kind,
    releaseSha,
    runId,
    stagingDeployRunId,
    artifactDigest,
    resultArtifactId,
    resultArtifactDigest,
    repository,
  ] = process.argv.slice(2);
  if (command === "create") {
    const resultBytes = await readFile(resultPath);
    const resultSha256 =
      `sha256:${createHash("sha256").update(resultBytes).digest("hex")}`;
    const result = JSON.parse(resultBytes.toString("utf8"));
    verifyStagingResult(result, {
      kind,
      releaseSha,
      repository: repository ?? process.env.GITHUB_REPOSITORY,
      runId: runId ?? process.env.GITHUB_RUN_ID,
      runAttempt: process.env.GITHUB_RUN_ATTEMPT,
      stagingDeployRunId,
      artifactDigest,
    });
    const attestation = buildStagingAttestation({
      kind,
      releaseSha,
      repository: repository ?? process.env.GITHUB_REPOSITORY,
      runId: runId ?? process.env.GITHUB_RUN_ID,
      runAttempt: process.env.GITHUB_RUN_ATTEMPT,
      stagingDeployRunId,
      artifactDigest,
      resultArtifactId,
      resultArtifactDigest,
      resultSha256,
    });
    await writeFile(filePath, `${JSON.stringify(attestation, null, 2)}\n`, { mode: 0o600 });
    process.stdout.write("Stagingattestation is aangemaakt.\n");
    return;
  }
  if (command === "verify") {
    const resultBytes = await readFile(resultPath);
    const resultSha256 =
      `sha256:${createHash("sha256").update(resultBytes).digest("hex")}`;
    verifyStagingResult(JSON.parse(resultBytes.toString("utf8")), {
      kind,
      releaseSha,
      repository: repository ?? process.env.GITHUB_REPOSITORY,
      runId,
      stagingDeployRunId,
      artifactDigest,
    });
    const attestation = JSON.parse(await readFile(filePath, "utf8"));
    verifyStagingAttestation(attestation, {
      kind,
      releaseSha,
      runId,
      stagingDeployRunId,
      artifactDigest,
      resultArtifactId,
      resultArtifactDigest,
      resultSha256,
      repository: repository ?? process.env.GITHUB_REPOSITORY,
    });
    process.stdout.write("Stagingattestation hoort bij exact de gevraagde release-run.\n");
    return;
  }
  throw new Error("Gebruik staging-attestation.mjs create|verify <attestation-pad> <resultaat-pad> <kind> <sha> <run-id> <staging-run-id> <sha256:digest> <resultaatartifact-id> <sha256:resultaatartifactdigest> [repository]");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : "Stagingattestation kon niet worden verwerkt"}\n`);
    process.exitCode = 1;
  });
}
