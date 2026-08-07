import {
  assertLegacyHealthIdentity,
  LEGACY_PRODUCTION_SHA,
} from "./legacy-health-identity.mjs";

const [baseUrl, environment, revision] = process.argv.slice(2);
if (
  !baseUrl
  || !["staging", "production"].includes(environment)
  || revision !== LEGACY_PRODUCTION_SHA
) process.exit(2);

const publicOrigin = environment === "staging"
  ? "https://staging-duindorp.dgwebservices.nl"
  : "https://duindorp.dgwebservices.nl";
const loopbackOrigin = environment === "staging"
  ? "http://127.0.0.1:14000"
  : "http://127.0.0.1:24000";
let base;
try {
  base = new URL(baseUrl);
} catch {
  process.exit(2);
}
if (
  ![publicOrigin, loopbackOrigin].includes(base.origin)
  || base.username
  || base.password
  || base.pathname !== "/"
  || base.search
  || base.hash
) process.exit(2);
const allowedOrigins = new Set(
  base.origin === loopbackOrigin
    ? [loopbackOrigin, publicOrigin]
    : [publicOrigin],
);

async function request(path, health = false, expectedFinalPath = path) {
  let target = new URL(path, baseUrl);
  const seen = new Set();
  let response;
  for (let redirect = 0; redirect <= 5; redirect += 1) {
    if (seen.has(target.href)) throw new Error(`${path}: redirectloop`);
    seen.add(target.href);
    try {
      response = await fetch(target, {
        redirect: "manual",
        signal: AbortSignal.timeout(5_000),
      });
    } catch {
      throw new Error(`${path}: verbinding mislukt`);
    }
    const location = response.headers.get("location");
    if (![301, 302, 303, 307, 308].includes(response.status) || !location) {
      break;
    }
    target = new URL(location, target);
    if (!allowedOrigins.has(target.origin)) {
      throw new Error(`${path}: redirect naar verkeerde host`);
    }
    if (redirect === 5) throw new Error(`${path}: te veel redirects`);
  }
  if (health) {
    if (
      response.status !== 200
      || !response.headers.get("content-type")?.toLowerCase()
        .includes("application/json")
    ) throw new Error(`${path}: ongeldige healthresponse`);
    assertLegacyHealthIdentity(
      await response.json(),
      environment,
      revision,
    );
    return;
  }
  if (response.status !== 200) {
    throw new Error(`${path}: eindigde met HTTP ${response.status}`);
  }
  if (target.pathname !== expectedFinalPath) {
    throw new Error(`${path}: eindigde onverwacht op ${target.pathname}`);
  }
}

try {
  await request("/api/health", true);
  await request("/");
  for (const route of ["/admin", "/uitgifte"]) {
    await request(route, false, "/staff/login");
  }
} catch (error) {
  process.stderr.write(
    `${error instanceof Error ? error.message : "Legacy HTTP-controle mislukt"}\n`,
  );
  process.exit(1);
}
