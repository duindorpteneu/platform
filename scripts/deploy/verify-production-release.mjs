const repository = process.env.GITHUB_REPOSITORY;
const token = process.env.GITHUB_TOKEN;
const tag = process.env.RELEASE_TAG;
const actor = process.env.GITHUB_ACTOR;
const sha = process.env.DEPLOY_SHA;

if (!repository || !token || !tag || !actor || !/^[a-f0-9]{40}$/.test(sha ?? "")) {
  console.error("Productionautorisatie mist verplichte GitHub-context.");
  process.exit(1);
}
if (!/^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(tag)) {
  console.error("Release-tag moet semantisch zijn, bijvoorbeeld v1.0.0.");
  process.exit(1);
}

const headers = {
  Accept: "application/vnd.github+json",
  Authorization: `Bearer ${token}`,
  "X-GitHub-Api-Version": "2022-11-28",
};

async function github(path) {
  const response = await fetch(`https://api.github.com/repos/${repository}${path}`, { headers, signal: AbortSignal.timeout(15_000) });
  if (!response.ok) throw new Error(`GitHub API gaf ${response.status} voor de releasecontrole`);
  return response.json();
}

const release = await github(`/releases/tags/${encodeURIComponent(tag)}`);
if (release.draft || release.prerelease) throw new Error("Production vereist een gepubliceerde, niet-prerelease GitHub Release.");
if (release.author?.login?.toLowerCase() === actor.toLowerCase()) {
  throw new Error("Vier-ogen-gate: de uitvoerder mag niet dezelfde persoon zijn als de releasepubliceerder.");
}

const workflows = [
  ["ci.yml", "push", "groene CI-push"],
  ["deploy-staging.yml", "workflow_run", "geslaagde stagingdeploy"],
];
for (const [workflow, expectedEvent, label] of workflows) {
  const runs = await github(`/actions/workflows/${workflow}/runs?head_sha=${sha}&status=success&per_page=20`);
  if (!runs.workflow_runs?.some((run) => run.conclusion === "success" && run.event === expectedEvent)) {
    throw new Error(`Geen ${label} gevonden voor commit ${sha.slice(0, 12)}.`);
  }
}

console.log(`Productionrelease ${tag} is geautoriseerd voor commit ${sha.slice(0, 12)}.`);
