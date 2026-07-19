import { chmod, readFile, rename, writeFile } from "node:fs/promises";

function fail(message) { console.error(message); process.exit(1); }
function validSha(value) { return /^[a-f0-9]{40}$/.test(value ?? ""); }
function validDigest(value) { return /^sha256:[a-f0-9]{64}$/.test(value ?? ""); }
async function read(path) {
  const data = JSON.parse(await readFile(path, "utf8"));
  if (!validSha(data.gitSha) || data.imageTag !== `duindorpteneu-app:${data.gitSha}` || !validDigest(data.imageDigest)) fail("Ongeldig release manifest.");
  return data;
}

const [command, ...args] = process.argv.slice(2);
if (command === "create") {
  const [target, environment, sha, tag, digest] = args;
  if (!target || !["build", "staging", "production"].includes(environment) || !validSha(sha) || tag !== `duindorpteneu-app:${sha}` || !validDigest(digest)) fail("Ongeldige manifestinvoer.");
  const temporary = `${target}.tmp-${process.pid}`;
  await writeFile(temporary, `${JSON.stringify({ gitSha: sha, imageTag: tag, imageDigest: digest, deployedAt: new Date().toISOString(), environment }, null, 2)}\n`, { mode: 0o600 });
  await chmod(temporary, 0o600);
  await rename(temporary, target);
  await chmod(target, 0o600);
} else if (command === "verify") {
  const [target, sha, digest] = args;
  const data = await read(target);
  if (data.gitSha !== sha || data.imageDigest !== digest) fail("Release manifest komt niet overeen met SHA/digest.");
  process.stdout.write(`${data.imageTag}\n`);
} else if (command === "compare") {
  const [first, second] = args;
  const a = await read(first); const b = await read(second);
  if (a.gitSha !== b.gitSha || a.imageTag !== b.imageTag || a.imageDigest !== b.imageDigest) fail("Staging- en buildmanifest verschillen.");
} else {
  fail("Gebruik: release-manifest.mjs create|verify|compare ...");
}
