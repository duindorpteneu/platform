import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { verifyStagingAttestation } from "./staging-attestation.mjs";
import {
  sha256Bytes,
  verifyStagingResult,
} from "./staging-result.mjs";
import { validateStagingManifest } from "./verify-staging-deploy.mjs";
import { validateRollbackEvidence } from "./rollback-evidence.mjs";
import {
  validateLegacyAdoptionResult,
  validateLegacyCaptureEvidence,
} from "./legacy-adoption-evidence.mjs";
import { validateRestoreEvidence } from "../staging/write-restore-evidence.mjs";
import {
  buildSendGridAcceptanceEvidence,
} from "../providers/sendgrid-acceptance-evidence.mjs";
import { createHash } from "node:crypto";

export const EVIDENCE = [
  {
    key: "deploy",
    runVariable: "STAGING_DEPLOY_RUN_ID",
    workflowPath: ".github/workflows/deploy.yml",
    requiredJobs: [
      "Preflight and quality gates",
      "Build immutable release image",
      "Deploy and verify staging",
    ],
    artifactNames: ({ releaseSha, runId, runAttempt }) => [
      `release-image-${releaseSha}`,
      `staging-release-${releaseSha}`,
      `staging-result-deploy-${runId}-${runAttempt}`,
      `staging-attestation-deploy-${runId}`,
    ],
    kind: "deploy",
  },
  {
    key: "core",
    runVariable: "CORE_ACCEPTANCE_RUN_ID",
    workflowPath: ".github/workflows/staging-core-acceptance.yml",
    requiredJobs: ["Staff MFA, role boundaries and mobile navigation"],
    artifactNames: ({ runId, runAttempt }) => [
      `staging-result-core-${runId}-${runAttempt}`,
      `staging-attestation-core-${runId}`,
    ],
    kind: "core",
  },
  {
    key: "phase-b",
    runVariable: "PHASE_B_ACCEPTANCE_RUN_ID",
    workflowPath: ".github/workflows/staging-phase-b-acceptance.yml",
    requiredJobs: [
      "Phase-B candidate matrix and deployed staging surfaces",
    ],
    artifactNames: ({ runId, runAttempt }) => [
      `staging-result-phase-b-${runId}-${runAttempt}`,
      `staging-attestation-phase-b-${runId}`,
    ],
    kind: "phase-b",
  },
  {
    key: "mollie",
    runVariable: "MOLLIE_ACCEPTANCE_RUN_ID",
    workflowPath: ".github/workflows/staging-mollie-acceptance.yml",
    requiredJobs: ["Mollie paid, mismatch and replay"],
    artifactNames: ({ runId, runAttempt }) => [
      `staging-result-mollie-${runId}-${runAttempt}`,
      `staging-attestation-mollie-${runId}`,
    ],
    kind: "mollie",
  },
  {
    key: "sendgrid",
    runVariable: "SENDGRID_ACCEPTANCE_RUN_ID",
    workflowPath: ".github/workflows/staging-provider-smoke.yml",
    requiredJobs: ["SendGrid Mail Send and signed event webhook"],
    artifactNames: ({ runId, runAttempt }) => [
      `staging-result-provider-sendgrid-${runId}-${runAttempt}`,
      `staging-attestation-provider-sendgrid-${runId}`,
    ],
    kind: "provider-sendgrid",
  },
  {
    key: "restore",
    runVariable: "RESTORE_ACCEPTANCE_RUN_ID",
    workflowPath: ".github/workflows/staging-restore-drill.yml",
    requiredJobs: ["Logical backup and network-isolated restore"],
    artifactNames: ({ runId, runAttempt }) => [
      `staging-result-restore-${runId}-${runAttempt}`,
      `staging-attestation-restore-${runId}`,
    ],
    kind: "restore",
  },
  {
    key: "rollback",
    runVariable: "ROLLBACK_ACCEPTANCE_RUN_ID",
    workflowPath: ".github/workflows/staging-rollback-drill.yml",
    requiredJobs: [
      "Artifact-bound application rollback and candidate restore",
    ],
    artifactNames: ({ runId, runAttempt }) => [
      `staging-result-rollback-${runId}-${runAttempt}`,
      `staging-attestation-rollback-${runId}`,
    ],
    kind: "rollback",
  },
  {
    key: "operations",
    runVariable: "OPERATIONS_ACCEPTANCE_RUN_ID",
    workflowPath: ".github/workflows/staging-operations.yml",
    requiredJobs: ["Exact-release scheduler and health acceptance"],
    artifactNames: ({ runId, runAttempt }) => [
      `staging-result-operations-${runId}-${runAttempt}`,
      `staging-attestation-operations-${runId}`,
    ],
    kind: "operations",
  },
];
const MAX_EVIDENCE_AGE_MS = 48 * 60 * 60 * 1000;
const CLOCK_SKEW_MS = 5 * 60 * 1000;

function required(values, name) {
  const value = values[name]?.trim();
  if (!value) throw new Error(`${name} ontbreekt`);
  return value;
}

function positiveInteger(value) {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
}

export function validatePromotionRun(run, expected) {
  if (!run
    || run.id !== expected.runId
    || run.workflow_id !== expected.workflowId
    || run.path !== expected.workflowPath
    || run.head_branch !== "main"
    || !expected.events.includes(run.event)
    || run.status !== "completed"
    || run.conclusion !== "success"
    || !Number.isSafeInteger(run.run_attempt)
    || run.run_attempt < 1
    || run.head_repository?.full_name !== expected.repository
    || run.head_sha !== expected.releaseSha) {
    throw new Error(`Workflowrun is niet canoniek groen: ${expected.workflowPath}`);
  }
  return run;
}

function timestamp(value, name) {
  const parsed = new Date(value);
  if (Number.isNaN(parsed.valueOf())) {
    throw new Error(`${name} bevat geen geldige tijd`);
  }
  return parsed.valueOf();
}

export function validateRunFreshness(run, {
  now = Date.now(),
  notBefore,
  maxAgeMs = MAX_EVIDENCE_AGE_MS,
} = {}) {
  const createdAt = timestamp(run?.created_at, "Workflowrun created_at");
  const updatedAt = timestamp(run?.updated_at, "Workflowrun updated_at");
  const nowAt = typeof now === "number" ? now : timestamp(now, "Huidige tijd");
  if (!Number.isSafeInteger(maxAgeMs) || maxAgeMs < 1) {
    throw new Error("Maximale bewijsleeftijd is ongeldig");
  }
  if (createdAt > updatedAt
    || updatedAt > nowAt + CLOCK_SKEW_MS
    || nowAt - updatedAt > maxAgeMs) {
    throw new Error("Workflowrun valt buiten het geldige bewijsvenster");
  }
  if (notBefore !== undefined) {
    const lowerBound = typeof notBefore === "number"
      ? notBefore
      : timestamp(notBefore, "Ondergrens workflowrun");
    if (createdAt < lowerBound - CLOCK_SKEW_MS) {
      throw new Error("Acceptatierun is gestart vóór de stagingdeploy was afgerond");
    }
  }
  return { createdAt, updatedAt };
}

export function validateAttestationFreshness(attestation, runWindow, {
  now = Date.now(),
  maxAgeMs = MAX_EVIDENCE_AGE_MS,
} = {}) {
  const createdAt = timestamp(attestation?.created_at, "Attestation created_at");
  const nowAt = typeof now === "number" ? now : timestamp(now, "Huidige tijd");
  if (createdAt < runWindow.createdAt - CLOCK_SKEW_MS
    || createdAt > runWindow.updatedAt + CLOCK_SKEW_MS
    || createdAt > nowAt + CLOCK_SKEW_MS
    || nowAt - createdAt > maxAgeMs) {
    throw new Error("Attestation valt buiten de geverifieerde workflowrun of is te oud");
  }
  return true;
}

export function validateRequiredJobs(jobs, requiredNames) {
  if (!Array.isArray(jobs)) throw new Error("Workflowjoblijst is ongeldig");
  for (const requiredName of requiredNames) {
    const matches = jobs.filter((job) => job?.name === requiredName);
    if (matches.length !== 1
      || matches[0].status !== "completed"
      || matches[0].conclusion !== "success") {
      throw new Error(`Verplichte acceptatiejob is niet exact eenmaal groen: ${requiredName}`);
    }
  }
  return true;
}

function artifactIsFromJob(artifact, job) {
  if (!job) return true;
  const artifactCreatedAt = timestamp(
    artifact?.created_at,
    "Releaseartifact created_at",
  );
  const jobStartedAt = timestamp(job?.started_at, "Workflowjob started_at");
  const jobCompletedAt = timestamp(job?.completed_at, "Workflowjob completed_at");
  if (jobStartedAt > jobCompletedAt) {
    throw new Error("Workflowjob heeft een ongeldig tijdvenster");
  }
  return artifactCreatedAt >= jobStartedAt
    && artifactCreatedAt <= jobCompletedAt;
}

export function validateArtifacts(artifacts, requiredNames, job = null) {
  if (!Array.isArray(artifacts)) throw new Error("Workflowartifactlijst is ongeldig");
  for (const requiredName of requiredNames) {
    const matches = artifacts.filter((artifact) =>
      artifact?.name === requiredName && artifactIsFromJob(artifact, job));
    if (matches.length !== 1
      || matches[0].expired !== false
      || !Number.isSafeInteger(matches[0].id)
      || matches[0].id < 1
      || typeof matches[0].digest !== "string"
      || !/^sha256:[a-f0-9]{64}$/u.test(matches[0].digest)) {
      throw new Error(`Verplicht releaseartifact ontbreekt, is dubbel of verlopen: ${requiredName}`);
    }
  }
  return true;
}

function findArtifactFromJob(artifacts, name, job) {
  return artifacts.find((artifact) =>
    artifact?.name === name && artifactIsFromJob(artifact, job));
}

export function validateProductionProtection(environment) {
  if (!environment || environment.name !== "production"
    || environment.deployment_branch_policy?.protected_branches !== false
    || environment.deployment_branch_policy?.custom_branch_policies !== true
    || !Array.isArray(environment.protection_rules)) {
    throw new Error("Production environment heeft geen gesloten main-deploymentbeleid");
  }
  const reviewerRules = environment.protection_rules.filter(
    (rule) => rule?.type === "required_reviewers",
  );
  if (reviewerRules.length !== 1
    || reviewerRules[0].prevent_self_review !== true
    || !Array.isArray(reviewerRules[0].reviewers)
    || reviewerRules[0].reviewers.length < 1
    || reviewerRules[0].reviewers.some((entry) => !entry?.reviewer
      || !["User", "Team"].includes(entry.type))) {
    throw new Error("Production environment mist onafhankelijke verplichte reviewerapproval");
  }
  return true;
}

export function validateDeploymentBranchPolicies(value) {
  if (!value || value.total_count !== 1 || !Array.isArray(value.branch_policies)
    || value.branch_policies.length !== 1
    || value.branch_policies[0]?.name !== "main"
    || !Number.isSafeInteger(value.branch_policies[0]?.id)
    || value.branch_policies[0].id < 1) {
    throw new Error("Production environment accepteert niet uitsluitend main");
  }
  return true;
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
  const evidenceRoot = required(process.env, "PROMOTION_EVIDENCE_ROOT");
  const stagingManifestPath = required(process.env, "STAGING_MANIFEST_PATH");
  if (!/^[a-f0-9]{40}$/u.test(releaseSha)) throw new Error("RELEASE_SHA is ongeldig");
  if (!/^[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,99})\/[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,99})$/u.test(repository)) {
    throw new Error("GITHUB_REPOSITORY is ongeldig");
  }

  validateProductionProtection(
    await fetchJson(token, repository, "/environments/production"),
  );
  validateDeploymentBranchPolicies(
    await fetchJson(token, repository, "/environments/production/deployment-branch-policies?per_page=100"),
  );
  const mainRef = await fetchJson(token, repository, "/git/ref/heads/main");
  if (mainRef?.object?.type !== "commit" || mainRef.object.sha !== releaseSha) {
    throw new Error("Gewone productiepromotie vereist dat release-SHA nog exact main is");
  }
  const stagingManifestBytes = await readFile(stagingManifestPath);
  const stagingManifest = validateStagingManifest(
    JSON.parse(stagingManifestBytes.toString("utf8")),
    releaseSha,
  );
  const stagingDeployRunId = positiveInteger(required(process.env, "STAGING_DEPLOY_RUN_ID"));
  if (!stagingDeployRunId) throw new Error("STAGING_DEPLOY_RUN_ID is ongeldig");
  const verificationNow = Date.now();
  let deployCompletedAt;
  const runIds = new Set();
  const manifestEvidence = {};

  for (const contract of EVIDENCE) {
    const runId = positiveInteger(required(process.env, contract.runVariable));
    if (!runId) throw new Error(`${contract.runVariable} is ongeldig`);
    runIds.add(runId);
    const workflow = await fetchJson(
      token,
      repository,
      `/actions/workflows/${contract.workflowPath.split("/").at(-1)}`,
    );
    if (!workflow
      || !Number.isSafeInteger(workflow.id)
      || workflow.path !== contract.workflowPath
      || workflow.state !== "active") {
      throw new Error(`Canonieke workflow ontbreekt of is niet actief: ${contract.workflowPath}`);
    }
    const run = validatePromotionRun(
      await fetchJson(token, repository, `/actions/runs/${runId}`),
      {
        runId,
        workflowId: workflow.id,
        workflowPath: contract.workflowPath,
        events: contract.key === "deploy" ? ["push", "workflow_dispatch"] : ["workflow_dispatch"],
        repository,
        releaseSha,
      },
    );
    const runWindow = validateRunFreshness(run, {
      now: verificationNow,
      notBefore: contract.key === "deploy" ? undefined : deployCompletedAt,
    });
    if (contract.key === "deploy") deployCompletedAt = runWindow.updatedAt;
    const jobResponse = await fetchJson(
      token,
      repository,
      `/actions/runs/${runId}/jobs?filter=latest&per_page=100`,
    );
    if (
      jobResponse.total_count !== jobResponse.jobs?.length
      || jobResponse.total_count > 100
    ) {
      throw new Error("Workflowjoblijst is onvolledig of niet gepagineerd");
    }
    validateRequiredJobs(jobResponse.jobs, contract.requiredJobs);
    const jobsByName = new Map(
      jobResponse.jobs.map((job) => [job?.name, job]),
    );
    const artifactResponse = await fetchJson(
      token,
      repository,
      `/actions/runs/${runId}/artifacts?per_page=100`,
    );
    if (
      artifactResponse.total_count !== artifactResponse.artifacts?.length
      || artifactResponse.total_count > 100
    ) {
      throw new Error("Workflowartifactlijst is onvolledig of niet gepagineerd");
    }
    const artifactNames = contract.artifactNames({
      releaseSha,
      runId,
      runAttempt: run.run_attempt,
    });
    let evidenceJob;
    if (contract.key === "deploy") {
      const buildJob = jobsByName.get("Build immutable release image");
      evidenceJob = jobsByName.get("Deploy and verify staging");
      validateArtifacts(
        artifactResponse.artifacts,
        artifactNames.slice(0, 1),
        buildJob,
      );
      validateArtifacts(
        artifactResponse.artifacts,
        artifactNames.slice(1),
        evidenceJob,
      );
    } else {
      evidenceJob = jobsByName.get(contract.requiredJobs[0]);
      validateArtifacts(
        artifactResponse.artifacts,
        artifactNames,
        evidenceJob,
      );
    }
    const resultArtifactName =
      `staging-result-${contract.kind}-${runId}-${run.run_attempt}`;
    const resultArtifact = findArtifactFromJob(
      artifactResponse.artifacts,
      resultArtifactName,
      evidenceJob,
    );
    if (!resultArtifact) {
      throw new Error(`Resultaatartifact ontbreekt: ${resultArtifactName}`);
    }
    const attestationArtifactName =
      `staging-attestation-${contract.kind}-${runId}`;
    const attestationArtifact = findArtifactFromJob(
      artifactResponse.artifacts,
      attestationArtifactName,
      evidenceJob,
    );
    if (!attestationArtifact) {
      throw new Error(
        `Attestationartifact ontbreekt: ${attestationArtifactName}`,
      );
    }
    const resultPath = join(
      evidenceRoot,
      contract.key,
      `staging-result-${contract.kind}.json`,
    );
    const resultBytes = await readFile(resultPath);
    let evidenceSha256;
    if (contract.kind === "restore") {
      const restoreEvidenceBytes = await readFile(join(
        evidenceRoot,
        contract.key,
        `duindorp-restore-${runId}-${run.run_attempt}-evidence.json`,
      ));
      evidenceSha256 = sha256Bytes(restoreEvidenceBytes);
      validateRestoreEvidence(
        JSON.parse(restoreEvidenceBytes.toString("utf8")),
        {
          releaseSha,
          artifactDigest: stagingManifest.artifactDigest,
          targetEnvironment: "staging",
        },
      );
    } else if (contract.kind === "rollback") {
      evidenceSha256 = sha256Bytes(await readFile(join(
        evidenceRoot,
        contract.key,
        "staging-application-rollback.json",
      )));
    } else if (contract.kind === "provider-sendgrid") {
      const sendGridEvidenceBytes = await readFile(join(
        evidenceRoot,
        contract.key,
        "sendgrid-acceptance-evidence.json",
      ));
      const sendGridEvidence = JSON.parse(
        sendGridEvidenceBytes.toString("utf8"),
      );
      const canonicalSendGridEvidence =
        buildSendGridAcceptanceEvidence(
          {
            schema_version: sendGridEvidence.schema_version,
            release_sha: sendGridEvidence.release_sha,
            checks: Object.fromEntries(
              Object.entries(sendGridEvidence.checks ?? {})
                .filter(([key]) =>
                  key !== "post_delivery_operational_health"),
            ),
            delivery: sendGridEvidence.delivery,
          },
          {
            status: sendGridEvidence.checks
              ?.post_delivery_operational_health === true
              ? "healthy"
              : "degraded",
            emailControl: {
              gateMatches: sendGridEvidence.checks
                ?.post_delivery_operational_health === true,
              providerConfigured: sendGridEvidence.checks
                ?.post_delivery_operational_health === true,
              keyFingerprintMatches: sendGridEvidence.checks
                ?.post_delivery_operational_health === true,
              testEventQuarantined:
                sendGridEvidence.delivery?.quarantined_events,
            },
          },
          releaseSha,
        );
      if (
        JSON.stringify(sendGridEvidence)
          !== JSON.stringify(canonicalSendGridEvidence)
      ) {
        throw new Error("SendGrid-acceptatiebewijs is niet canoniek");
      }
      evidenceSha256 = sha256Bytes(sendGridEvidenceBytes);
    }
    const result = verifyStagingResult(
      JSON.parse(resultBytes.toString("utf8")),
      {
        kind: contract.kind,
        releaseSha,
        repository,
        runId,
        runAttempt: run.run_attempt,
        stagingDeployRunId,
        artifactDigest: stagingManifest.artifactDigest,
        evidenceSha256,
      },
    );
    const attestationBytes = await readFile(join(
      evidenceRoot,
      contract.key,
      `staging-attestation-${contract.kind}.json`,
    ));
    const attestation = verifyStagingAttestation(
      JSON.parse(attestationBytes.toString("utf8")),
      {
        kind: contract.kind,
        releaseSha,
        repository,
        runId,
        runAttempt: run.run_attempt,
        stagingDeployRunId,
        artifactDigest: stagingManifest.artifactDigest,
        resultArtifactId: resultArtifact.id,
        resultArtifactDigest: resultArtifact.digest,
        resultSha256: sha256Bytes(resultBytes),
      },
    );
    validateAttestationFreshness(attestation, runWindow, {
      now: verificationNow,
    });
    validateAttestationFreshness(
      { created_at: result.created_at },
      runWindow,
      { now: verificationNow },
    );
    if (
      new Date(result.created_at).valueOf()
      > new Date(attestation.created_at).valueOf()
    ) {
      throw new Error("Stagingresultaat is na de attestation gemaakt");
    }
    manifestEvidence[contract.key] = {
      workflow_kind: contract.kind,
      workflow_run_id: runId,
      workflow_run_attempt: run.run_attempt,
      result_artifact_id: resultArtifact.id,
      result_artifact_digest: resultArtifact.digest,
      result_sha256: sha256Bytes(resultBytes),
      attestation_artifact_id: attestationArtifact.id,
      attestation_artifact_digest: attestationArtifact.digest,
      attestation_sha256: sha256Bytes(attestationBytes),
      evidence_sha256: evidenceSha256 ?? null,
    };
  }
  const rollbackEvidence = validateRollbackEvidence(
    JSON.parse(await readFile(
      join(
        evidenceRoot,
        "rollback",
        "staging-application-rollback.json",
      ),
      "utf8",
    )),
    stagingManifest,
  );
  const legacyAdoptionRunValue =
    process.env.LEGACY_ADOPTION_RUN_ID?.trim() ?? "";
  if (
    rollbackEvidence.previous_health_contract
      === "legacy-v1-exact-four-fields"
  ) {
    const legacyAdoptionRunId = positiveInteger(legacyAdoptionRunValue);
    if (
      !legacyAdoptionRunId
      || legacyAdoptionRunId
        !== rollbackEvidence.legacy_adoption_run_id
      || runIds.has(legacyAdoptionRunId)
    ) {
      throw new Error("Legacy adoptierun-ID is ongeldig of hergebruikt");
    }
    const workflowPath =
      ".github/workflows/adopt-legacy-production.yml";
    const workflow = await fetchJson(
      token,
      repository,
      "/actions/workflows/adopt-legacy-production.yml",
    );
    if (
      !workflow
      || !Number.isSafeInteger(workflow.id)
      || workflow.path !== workflowPath
      || workflow.state !== "active"
    ) throw new Error("Legacy adoptieworkflow is niet canoniek actief");
    const adoptionRun = validatePromotionRun(
      await fetchJson(
        token,
        repository,
        `/actions/runs/${legacyAdoptionRunId}`,
      ),
      {
        runId: legacyAdoptionRunId,
        workflowId: workflow.id,
        workflowPath,
        events: ["workflow_dispatch"],
        repository,
        releaseSha,
      },
    );
    validateRunFreshness(adoptionRun, {
      now: verificationNow,
      notBefore: deployCompletedAt,
    });
    const adoptionJobs = await fetchJson(
      token,
      repository,
      `/actions/runs/${legacyAdoptionRunId}/jobs?filter=latest&per_page=100`,
    );
    validateRequiredJobs(adoptionJobs.jobs, [
      "Capture manifest-bound legacy production image read-only",
      "Prove legacy rollback and restore exact candidate",
    ]);
    const adoptionArtifacts = await fetchJson(
      token,
      repository,
      `/actions/runs/${legacyAdoptionRunId}/artifacts?per_page=100`,
    );
    validateArtifacts(adoptionArtifacts.artifacts, [
      `legacy-production-adoption-${legacyAdoptionRunId}-${adoptionRun.run_attempt}`,
    ]);
    const adoptionRoot = required(
      process.env,
      "LEGACY_ADOPTION_EVIDENCE_ROOT",
    );
    const capturePath = join(
      adoptionRoot,
      "legacy-capture-evidence.json",
    );
    const captureBytes = await readFile(capturePath);
    const legacyManifest = JSON.parse(await readFile(
      join(adoptionRoot, "LEGACY_RELEASE_MANIFEST"),
      "utf8",
    ));
    const capture = validateLegacyCaptureEvidence(
      JSON.parse(captureBytes),
      legacyManifest,
      {
        runId: legacyAdoptionRunId,
        runAttempt: adoptionRun.run_attempt,
        notBefore: adoptionRun.run_started_at ?? adoptionRun.created_at,
        notAfter: adoptionRun.updated_at,
      },
    );
    const captureHash = `sha256:${createHash("sha256")
      .update(captureBytes).digest("hex")}`;
    if (
      captureHash
        !== rollbackEvidence.legacy_adoption_evidence_sha256
    ) throw new Error("Rollbackbewijs hoort niet bij de adoptiecapture");
    const adoption = validateLegacyAdoptionResult(
      JSON.parse(await readFile(
        join(adoptionRoot, "legacy-adoption-result.json"),
        "utf8",
      )),
      captureHash,
      {
        candidateReleaseSha: releaseSha,
        candidateArtifactDigest: stagingManifest.artifactDigest,
        runId: legacyAdoptionRunId,
        runAttempt: adoptionRun.run_attempt,
        notBefore: adoptionRun.run_started_at ?? adoptionRun.created_at,
        notAfter: adoptionRun.updated_at,
      },
    );
    if (
      new Date(adoption.adopted_at).valueOf()
        < new Date(capture.captured_at).valueOf()
      ||
      capture.legacy_manifest.gitSha
        !== rollbackEvidence.previous_release_sha
      || capture.legacy_manifest.artifactDigest
        !== rollbackEvidence.previous_artifact_digest
    ) throw new Error("Legacy manifest wijkt af van het rollbacktarget");
  } else if (legacyAdoptionRunValue) {
    throw new Error("Gewone promotie mag geen legacy adoptierun opgeven");
  }
  const promotionManifestPath =
    process.env.PROMOTION_EVIDENCE_MANIFEST_PATH?.trim();
  if (promotionManifestPath) {
    const promotionManifest = {
      schema_version: 1,
      result: "passed",
      repository,
      release_sha: releaseSha,
      artifact_digest: stagingManifest.artifactDigest,
      staging_manifest_sha256: sha256Bytes(stagingManifestBytes),
      staging_deploy_run_id: stagingDeployRunId,
      evidence: manifestEvidence,
      checks: {
        all_runs_fresh_and_green: true,
        all_required_jobs_green: true,
        artifact_api_digests_bound: true,
        result_bytes_and_semantics_bound: true,
        restore_and_rollback_evidence_bound: true,
      },
      created_at: new Date(verificationNow).toISOString(),
    };
    await writeFile(
      promotionManifestPath,
      `${JSON.stringify(promotionManifest, null, 2)}\n`,
      { mode: 0o600 },
    );
  }
  process.stdout.write("Alle staging-, provider-, restore-, rollback- en operationsbewijzen horen bij exact hetzelfde artifact.\n");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : "Promotiebewijs kon niet worden geverifieerd"}\n`);
    process.exitCode = 1;
  });
}
