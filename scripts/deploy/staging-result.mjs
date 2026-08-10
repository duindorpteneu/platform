import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const REQUIRED_CHECKS = Object.freeze({
  deploy: [
    "database_migrations_applied",
    "immutable_artifact_deployed",
    "public_health_exact",
    "provider_send_disabled_during_deploy",
  ],
  core: [
    "fixture_cleanup_completed",
    "mobile_navigation",
    "role_boundaries",
    "staff_mfa",
  ],
  "phase-b": [
    "accessibility_browser",
    "capacity_contract",
    "database_upgrade",
    "deployed_role_surfaces",
    "dependency_security",
    "log_privacy",
    "production_build",
    "rls_and_concurrency",
    "unit_and_integration",
  ],
  mollie: [
    "amount_currency_tenant_binding",
    "checkout",
    "paid_webhook",
    "refund_workflow",
    "replay_idempotency",
  ],
  operations: [
    "provider_send_enabled",
    "scheduler_cycle_one",
    "scheduler_cycle_two",
    "scheduler_health",
  ],
  restore: [
    "data_hmac_exact",
    "network_isolated_restore",
    "owner_acl_rls_exact",
    "role_and_identity_contract",
    "schema_definition_exact",
  ],
  rollback: [
    "candidate_restored",
    "database_rollback_not_attempted",
    "previous_artifact_started",
    "provider_send_disabled_during_rollback",
    "scheduler_health_restored",
  ],
  "provider-sendgrid": [
    "account_identity",
    "app_request_idempotency",
    "inbox_delivery",
    "mail_send_scope",
    "post_delivery_operational_health",
    "signed_delivery_event",
    "webhook_configuration",
  ],
  "provider-mollie": [
    "credential_test_mode",
    "profile_identity",
  ],
});

const EXACT_KEYS = [
  "artifact_digest",
  "checks",
  "created_at",
  "evidence_sha256",
  "release_sha",
  "repository",
  "result",
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
  return typeof value === "string"
    && /^sha256:[a-f0-9]{64}$/u.test(value);
}

function validRepository(value) {
  return typeof value === "string"
    && /^[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,99})\/[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,99})$/u.test(value);
}

function positiveInteger(value) {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
}

function canonicalChecks(kind) {
  const names = REQUIRED_CHECKS[kind];
  if (!names) throw new Error("Resultaatsoort is ongeldig");
  return Object.fromEntries(names.map((name) => [name, true]));
}

export function sha256Bytes(value) {
  return `sha256:${createHash("sha256").update(value).digest("hex")}`;
}

export function buildStagingResult({
  kind,
  releaseSha,
  repository,
  runId,
  runAttempt,
  stagingDeployRunId,
  artifactDigest,
  evidenceSha256 = null,
  createdAt,
}) {
  if (!REQUIRED_CHECKS[kind]) throw new Error("Resultaatsoort is ongeldig");
  if (!validSha(releaseSha)) throw new Error("Release-SHA is ongeldig");
  if (!validDigest(artifactDigest)) throw new Error("Artefactdigest is ongeldig");
  if (!validRepository(repository)) throw new Error("Repository is ongeldig");
  if (evidenceSha256 !== null && !validDigest(evidenceSha256)) {
    throw new Error("Inhoudelijk bewijsdigest is ongeldig");
  }
  if (
    ["restore", "rollback", "provider-sendgrid"].includes(kind)
      !== (evidenceSha256 !== null)
  ) {
    throw new Error(
      "Restore, rollback en SendGrid vereisen exact één inhoudelijk bewijsbestand",
    );
  }
  const parsedRunId = positiveInteger(runId);
  const parsedAttempt = positiveInteger(runAttempt);
  const parsedDeployRunId = positiveInteger(stagingDeployRunId);
  if (!parsedRunId || !parsedAttempt || !parsedDeployRunId) {
    throw new Error("Workflow-runidentiteit is ongeldig");
  }
  if (kind === "deploy" && parsedDeployRunId !== parsedRunId) {
    throw new Error("Deployresultaat moet naar de eigen workflowrun verwijzen");
  }
  const timestamp = new Date(createdAt ?? Date.now());
  if (Number.isNaN(timestamp.valueOf())) throw new Error("Resultaattijd is ongeldig");
  return {
    schema_version: 1,
    result: "passed",
    workflow_kind: kind,
    release_sha: releaseSha,
    artifact_digest: artifactDigest,
    repository,
    workflow_run_id: parsedRunId,
    workflow_run_attempt: parsedAttempt,
    staging_deploy_run_id: parsedDeployRunId,
    checks: canonicalChecks(kind),
    evidence_sha256: evidenceSha256,
    created_at: timestamp.toISOString(),
  };
}

export function verifyStagingResult(value, expected) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Stagingresultaat is ongeldig");
  }
  const keys = Object.keys(value).sort();
  if (
    keys.length !== EXACT_KEYS.length
    || keys.some((key, index) => key !== EXACT_KEYS[index])
  ) {
    throw new Error("Stagingresultaat bevat onverwachte velden");
  }
  const canonical = buildStagingResult({
    kind: value.workflow_kind,
    releaseSha: value.release_sha,
    repository: value.repository,
    runId: value.workflow_run_id,
    runAttempt: value.workflow_run_attempt,
    stagingDeployRunId: value.staging_deploy_run_id,
    artifactDigest: value.artifact_digest,
    evidenceSha256: value.evidence_sha256,
    createdAt: value.created_at,
  });
  if (
    value.result !== "passed"
    || JSON.stringify(value) !== JSON.stringify(canonical)
  ) {
    throw new Error("Stagingresultaat is niet canoniek groen");
  }
  if (
    canonical.workflow_kind !== expected.kind
    || canonical.release_sha !== expected.releaseSha
    || canonical.repository !== expected.repository
    || canonical.workflow_run_id !== positiveInteger(expected.runId)
    || (
      expected.runAttempt !== undefined
      && canonical.workflow_run_attempt
        !== positiveInteger(expected.runAttempt)
    )
    || canonical.staging_deploy_run_id
      !== positiveInteger(expected.stagingDeployRunId)
    || canonical.artifact_digest !== expected.artifactDigest
    || (
      expected.evidenceSha256 !== undefined
      && canonical.evidence_sha256 !== expected.evidenceSha256
    )
  ) {
    throw new Error("Stagingresultaat hoort niet bij de gevraagde release-run");
  }
  return canonical;
}

async function main() {
  const [
    command,
    filePath,
    kind,
    releaseSha,
    runId,
    stagingDeployRunId,
    artifactDigest,
    evidencePath,
    repository,
  ] = process.argv.slice(2);
  if (command !== "create") {
    throw new Error(
      "Gebruik staging-result.mjs create <pad> <kind> <sha> <run-id> <staging-run-id> <sha256:digest> [bewijs-pad|-] [repository]",
    );
  }
  const evidenceSha256 = evidencePath && evidencePath !== "-"
    ? sha256Bytes(await readFile(evidencePath))
    : null;
  const result = buildStagingResult({
    kind,
    releaseSha,
    repository: repository ?? process.env.GITHUB_REPOSITORY,
    runId: runId ?? process.env.GITHUB_RUN_ID,
    runAttempt: process.env.GITHUB_RUN_ATTEMPT,
    stagingDeployRunId,
    artifactDigest,
    evidenceSha256,
  });
  await writeFile(filePath, `${JSON.stringify(result, null, 2)}\n`, {
    mode: 0o600,
  });
  process.stdout.write("Canoniek stagingresultaat is aangemaakt.\n");
}

if (
  process.argv[1]
  && import.meta.url === pathToFileURL(process.argv[1]).href
) {
  main().catch((error) => {
    process.stderr.write(
      `${error instanceof Error ? error.message : "Stagingresultaat kon niet worden gemaakt"}\n`,
    );
    process.exitCode = 1;
  });
}
