const validSha = (value) => /^[a-f0-9]{40}$/u.test(value ?? "");
const validDigest = (value) => /^sha256:[a-f0-9]{64}$/u.test(value ?? "");

export function assertHealthIdentity(
  body,
  environment,
  revision,
  artifactDigest,
) {
  if (
    !body
    || body.status !== "ok"
    || body.service !== "duindorpteneu"
    || body.environment !== environment
    || body.revision !== revision
    || body.artifactDigest !== artifactDigest
    || !["staging", "production"].includes(environment)
    || !validSha(revision)
    || !validDigest(artifactDigest)
  ) {
    throw new Error("verkeerde release-identiteit");
  }
}
