import { chmod, readFile, rename, writeFile } from "node:fs/promises";

function fail(message) { console.error(message); process.exit(1); }
function validSha(value) { return /^[a-f0-9]{40}$/.test(value ?? ""); }
function validDigest(value) { return /^sha256:[a-f0-9]{64}$/.test(value ?? ""); }
async function read(path) {
  const data = JSON.parse(await readFile(path, "utf8"));
  if (
    data.schemaVersion !== 2
    || !validSha(data.gitSha)
    || data.imageTag !== `duindorpteneu-app:${data.gitSha}`
    || !validDigest(data.imageDigest)
    || !validDigest(data.imageConfigDigest)
    || !validDigest(data.artifactDigest)
  ) fail("Ongeldig release manifest.");
  return data;
}

const [command, ...args] = process.argv.slice(2);
if (command === "create") {
  const [target, environment, sha, tag, digest, configDigest, artifactDigest] = args;
  if (
    !target
    || !["build", "staging", "production"].includes(environment)
    || !validSha(sha)
    || tag !== `duindorpteneu-app:${sha}`
    || !validDigest(digest)
    || !validDigest(configDigest)
    || !validDigest(artifactDigest)
  ) fail("Ongeldige manifestinvoer.");
  const temporary = `${target}.tmp-${process.pid}`;
  await writeFile(temporary, `${JSON.stringify({
    schemaVersion: 2,
    gitSha: sha,
    imageTag: tag,
    imageDigest: digest,
    imageConfigDigest: configDigest,
    artifactDigest,
    deployedAt: new Date().toISOString(),
    environment,
  }, null, 2)}\n`, { mode: 0o600 });
  await chmod(temporary, 0o600);
  await rename(temporary, target);
  await chmod(target, 0o600);
} else if (command === "verify") {
  const [target, sha, digest, configDigest, artifactDigest] = args;
  const data = await read(target);
  if (
    data.gitSha !== sha
    || data.imageDigest !== digest
    || data.imageConfigDigest !== configDigest
    || data.artifactDigest !== artifactDigest
  ) fail("Release manifest komt niet overeen met SHA/digests.");
  process.stdout.write(`${data.imageTag}\n`);
} else if (command === "compare") {
  const [first, second] = args;
  const a = await read(first); const b = await read(second);
  if (
    a.gitSha !== b.gitSha
    || a.imageTag !== b.imageTag
    || a.imageDigest !== b.imageDigest
    || a.imageConfigDigest !== b.imageConfigDigest
    || a.artifactDigest !== b.artifactDigest
  ) fail("Staging- en buildmanifest verschillen.");
} else if (command === "fields") {
  const [target] = args;
  const data = await read(target);
  process.stdout.write(`${data.imageDigest} ${data.imageConfigDigest} ${data.artifactDigest}\n`);
} else {
  fail("Gebruik: release-manifest.mjs create|verify|compare|fields ...");
}
