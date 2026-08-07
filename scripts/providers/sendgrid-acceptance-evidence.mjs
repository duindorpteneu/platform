import { readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const SHA_PATTERN = /^[a-f0-9]{40}$/u;
const OBSERVATION_CHECKS = [
  "account_identity",
  "app_request_idempotency",
  "inbox_delivery",
  "mail_send_scope",
  "signed_delivery_event",
  "webhook_configuration",
];
const FINAL_CHECKS = [
  ...OBSERVATION_CHECKS,
  "post_delivery_operational_health",
].sort();
const DELIVERY_KEYS = [
  "application_requests",
  "deferred_events",
  "delivered_events",
  "failure_events",
  "inbox_messages",
  "provider_events",
  "quarantined_events",
];

function hasExactKeys(value, keys) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return false;
  }
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  return actual.length === expected.length
    && actual.every((key, index) => key === expected[index]);
}

function nonnegativeInteger(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

export function validateSendGridObservation(value, releaseSha) {
  if (
    !SHA_PATTERN.test(releaseSha)
    || !hasExactKeys(
      value,
      ["checks", "delivery", "release_sha", "schema_version"],
    )
    || value.schema_version !== 1
    || value.release_sha !== releaseSha
    || !hasExactKeys(value.checks, OBSERVATION_CHECKS)
    || !Object.values(value.checks).every((check) => check === true)
    || !hasExactKeys(value.delivery, DELIVERY_KEYS)
    || !Object.values(value.delivery).every(nonnegativeInteger)
    || value.delivery.application_requests !== 2
    || value.delivery.inbox_messages !== 1
    || value.delivery.delivered_events < 1
    || value.delivery.failure_events !== 0
    || value.delivery.quarantined_events !== 0
    || value.delivery.provider_events
      !== value.delivery.delivered_events
        + value.delivery.deferred_events
        + value.delivery.failure_events
  ) {
    throw new Error("SENDGRID_ACCEPTANCE_OBSERVATION_INVALID");
  }
  return value;
}

export function validatePostDeliveryHealth(value) {
  if (
    !value
    || typeof value !== "object"
    || Array.isArray(value)
    || value.status !== "healthy"
    || value.emailControl?.gateMatches !== true
    || value.emailControl?.providerConfigured !== true
    || value.emailControl?.keyFingerprintMatches !== true
    || value.emailControl?.testEventQuarantined !== 0
  ) {
    throw new Error("SENDGRID_POST_DELIVERY_HEALTH_INVALID");
  }
  return true;
}

export function buildSendGridAcceptanceEvidence(
  observation,
  health,
  releaseSha,
) {
  const validated =
    validateSendGridObservation(observation, releaseSha);
  validatePostDeliveryHealth(health);
  return {
    schema_version: 1,
    release_sha: releaseSha,
    checks: Object.fromEntries(
      FINAL_CHECKS.map((key) => [key, true]),
    ),
    delivery: { ...validated.delivery },
  };
}

async function main() {
  const [
    command,
    observationPath,
    healthPath,
    evidencePath,
    releaseSha,
  ] = process.argv.slice(2);
  if (
    command !== "finalize"
    || !observationPath
    || !healthPath
    || !evidencePath
    || !releaseSha
  ) {
    throw new Error(
      "Gebruik sendgrid-acceptance-evidence.mjs finalize <observatie> <health> <bewijs> <release-sha>",
    );
  }
  const [observationBytes, healthBytes] = await Promise.all([
    readFile(observationPath),
    readFile(healthPath),
  ]);
  const evidence = buildSendGridAcceptanceEvidence(
    JSON.parse(observationBytes.toString("utf8")),
    JSON.parse(healthBytes.toString("utf8")),
    releaseSha,
  );
  await writeFile(
    evidencePath,
    `${JSON.stringify(evidence, null, 2)}\n`,
    { mode: 0o600 },
  );
  process.stdout.write(
    "Privacyveilig SendGrid-acceptatiebewijs is aangemaakt.\n",
  );
}

if (
  process.argv[1]
  && import.meta.url === pathToFileURL(process.argv[1]).href
) {
  main().catch((error) => {
    process.stderr.write(
      `${error instanceof Error
        ? error.message
        : "SENDGRID_ACCEPTANCE_EVIDENCE_FAILED"}\n`,
    );
    process.exitCode = 1;
  });
}
