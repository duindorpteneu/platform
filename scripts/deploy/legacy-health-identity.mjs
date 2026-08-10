const EXACT_KEYS = ["environment", "revision", "service", "status"];

export const LEGACY_PRODUCTION_SHA =
  "a79c8d843d75e90810ccceb228538c6368d2198b";

export function assertLegacyHealthIdentity(value, environment, revision) {
  if (
    !value
    || typeof value !== "object"
    || Array.isArray(value)
    || Object.keys(value).sort().some((key, index) => key !== EXACT_KEYS[index])
    || Object.keys(value).length !== EXACT_KEYS.length
    || value.status !== "ok"
    || value.service !== "duindorpteneu"
    || value.environment !== environment
    || value.revision !== revision
    || !["staging", "production"].includes(environment)
    || revision !== LEGACY_PRODUCTION_SHA
  ) {
    throw new Error("Legacy health-identiteit is ongeldig");
  }
  return value;
}
