import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const exactKeys = [
  "app_health_proven",
  "created_at",
  "current_artifact_digest",
  "current_config_digest",
  "current_oci_digest",
  "current_release_sha",
  "database_rollback_attempted",
  "environment",
  "legacy_adoption_evidence_sha256",
  "legacy_adoption_run_id",
  "previous_artifact_digest",
  "previous_config_digest",
  "previous_health_contract",
  "previous_oci_digest",
  "previous_release_sha",
  "previous_scheduler_expected",
  "restored_current_release",
  "result",
  "rollback_provider_send_disabled",
  "scheduler_health_proven",
  "schema_version",
];

function validSha(value) {
  return typeof value === "string" && /^[a-f0-9]{40}$/u.test(value);
}

function validDigest(value) {
  return typeof value === "string"
    && /^sha256:[a-f0-9]{64}$/u.test(value);
}

function validManifest(value) {
  return value
    && typeof value === "object"
    && !Array.isArray(value)
    && value.schemaVersion === 2
    && validSha(value.gitSha)
    && value.imageTag === `duindorpteneu-app:${value.gitSha}`
    && validDigest(value.imageDigest)
    && validDigest(value.imageConfigDigest)
    && validDigest(value.artifactDigest);
}

function matchesManifest(evidence, prefix, manifest) {
  return evidence[`${prefix}_release_sha`] === manifest.gitSha
    && evidence[`${prefix}_oci_digest`] === manifest.imageDigest
    && evidence[`${prefix}_config_digest`] === manifest.imageConfigDigest
    && evidence[`${prefix}_artifact_digest`] === manifest.artifactDigest;
}

export function validateRollbackEvidence(
  value,
  candidateManifest,
  productionCurrentManifest = null,
) {
  if (
    !value
    || typeof value !== "object"
    || Array.isArray(value)
    || Object.keys(value).length !== exactKeys.length
    || Object.keys(value).sort().some((key, index) => key !== exactKeys[index])
    || value.schema_version !== 2
    || value.result !== "passed"
    || value.environment !== "staging"
    || !validSha(value.current_release_sha)
    || !validSha(value.previous_release_sha)
    || value.current_release_sha === value.previous_release_sha
    || !validDigest(value.current_oci_digest)
    || !validDigest(value.current_config_digest)
    || !validDigest(value.current_artifact_digest)
    || !validDigest(value.previous_oci_digest)
    || !validDigest(value.previous_config_digest)
    || !validDigest(value.previous_artifact_digest)
    || !["artifact-v2", "legacy-v1-exact-four-fields"].includes(
      value.previous_health_contract,
    )
    || typeof value.previous_scheduler_expected !== "boolean"
    || value.restored_current_release !== true
    || value.app_health_proven !== true
    || value.scheduler_health_proven !== true
    || value.rollback_provider_send_disabled !== true
    || value.database_rollback_attempted !== false
    || Number.isNaN(new Date(value.created_at).valueOf())
  ) {
    throw new Error("Applicatierollbackbewijs is ongeldig");
  }
  const legacyRollback =
    value.previous_health_contract === "legacy-v1-exact-four-fields";
  if (
    legacyRollback
      ? (
          value.previous_release_sha
            !== "a79c8d843d75e90810ccceb228538c6368d2198b"
          || value.previous_scheduler_expected !== false
          || !validDigest(value.legacy_adoption_evidence_sha256)
          || !Number.isSafeInteger(value.legacy_adoption_run_id)
          || value.legacy_adoption_run_id < 1
        )
      : (
          value.previous_scheduler_expected !== true
          ||
          value.legacy_adoption_evidence_sha256 !== null
          || value.legacy_adoption_run_id !== null
        )
  ) {
    throw new Error("Rollbackbewijs heeft een ongeldige healthcontractbrug");
  }
  if (
    !validManifest(candidateManifest)
    || !matchesManifest(value, "current", candidateManifest)
  ) {
    throw new Error("Rollbackbewijs hoort niet bij de releasecandidate");
  }
  if (
    productionCurrentManifest !== null
    && (
      !validManifest(productionCurrentManifest)
      || !matchesManifest(value, "previous", productionCurrentManifest)
    )
  ) {
    throw new Error(
      "Rollbacktarget is niet exact de actuele productionrelease",
    );
  }
  return value;
}

async function main() {
  const [evidencePath, candidateManifestPath, productionManifestPath] =
    process.argv.slice(2);
  if (!evidencePath || !candidateManifestPath) {
    throw new Error(
      "Gebruik rollback-evidence.mjs <bewijs> <candidate-manifest> [production-manifest]",
    );
  }
  const evidence = JSON.parse(await readFile(evidencePath, "utf8"));
  const candidate = JSON.parse(
    await readFile(candidateManifestPath, "utf8"),
  );
  const production = productionManifestPath
    ? JSON.parse(await readFile(productionManifestPath, "utf8"))
    : null;
  validateRollbackEvidence(evidence, candidate, production);
  process.stdout.write(
    production
      ? "Rollbackbewijs is exact gebonden aan candidate en actuele productionrelease.\n"
      : "Rollbackbewijs is exact gebonden aan de releasecandidate.\n",
  );
}

if (
  process.argv[1]
  && import.meta.url === pathToFileURL(process.argv[1]).href
) {
  main().catch((error) => {
    process.stderr.write(
      `${error instanceof Error ? error.message : "Rollbackbewijs is ongeldig"}\n`,
    );
    process.exitCode = 1;
  });
}
