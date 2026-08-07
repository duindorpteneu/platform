import { pathToFileURL } from "node:url";

const CI_WORKFLOW_PATH = ".github/workflows/ci.yml";
const TERMINAL_FAILURES = new Set(["failure", "cancelled", "timed_out", "action_required", "stale"]);
const REQUIRED_CI_JOBS = [
  "Application quality gates",
  "Supabase migration and pgTAP gates",
];

function required(values, name) {
  const value = values[name]?.trim();
  if (!value) throw new Error(`${name} ontbreekt`);
  return value;
}

export function selectCiState(runs, releaseSha, repository, workflowId) {
  if (!Array.isArray(runs)) throw new Error("CI-runlijst is ongeldig");
  const matching = runs.filter((run) => run
    && run.workflow_id === workflowId
    && run.head_sha === releaseSha
    && run.head_branch === "main"
    && run.event === "push"
    && run.path === CI_WORKFLOW_PATH
    && run.head_repository?.full_name === repository);
  const latestRun = matching.toSorted((left, right) => {
    const runNumberDifference = (Number(right.run_number) || 0) - (Number(left.run_number) || 0);
    if (runNumberDifference !== 0) return runNumberDifference;
    const attemptDifference = (Number(right.run_attempt) || 0) - (Number(left.run_attempt) || 0);
    if (attemptDifference !== 0) return attemptDifference;
    return (Number(right.id) || 0) - (Number(left.id) || 0);
  })[0];
  if (!latestRun) return { state: "missing" };
  if (latestRun.status === "completed" && latestRun.conclusion === "success") {
    return {
      state: "success",
      runId: latestRun.id,
      runAttempt: latestRun.run_attempt,
    };
  }
  if (latestRun.status === "queued" || latestRun.status === "in_progress" || latestRun.status === "waiting") {
    return { state: "pending" };
  }
  if (latestRun.status === "completed" && TERMINAL_FAILURES.has(latestRun.conclusion)) {
    return { state: "failed" };
  }
  return { state: "failed" };
}

export function validateCiRun(run, expected) {
  if (!run
    || run.id !== expected.runId
    || run.workflow_id !== expected.workflowId
    || run.path !== CI_WORKFLOW_PATH
    || run.head_sha !== expected.releaseSha
    || run.head_branch !== "main"
    || run.event !== "push"
    || run.status !== "completed"
    || run.conclusion !== "success"
    || run.head_repository?.full_name !== expected.repository
    || !Number.isSafeInteger(run.run_attempt)
    || run.run_attempt < 1) {
    throw new Error("De geselecteerde CI-run wijkt af van het canonieke releasecontract");
  }
  return run;
}

export function validateCiJobs(jobs) {
  if (!Array.isArray(jobs)) throw new Error("CI-joblijst is ongeldig");
  for (const requiredName of REQUIRED_CI_JOBS) {
    const matching = jobs.filter((job) => job?.name === requiredName);
    if (matching.length !== 1
      || matching[0].status !== "completed"
      || matching[0].conclusion !== "success") {
      throw new Error(`Verplichte CI-job is niet exact eenmaal groen: ${requiredName}`);
    }
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

async function fetchWorkflow(token, repository) {
  const body = await fetchJson(token, repository, "/actions/workflows/ci.yml");
  if (!body
    || !Number.isSafeInteger(body.id)
    || body.path !== CI_WORKFLOW_PATH
    || body.state !== "active") {
    throw new Error("Canonieke CI-workflow ontbreekt of is niet actief");
  }
  return body;
}

async function fetchRuns(token, repository, workflowId, releaseSha) {
  const query = new URLSearchParams({
    event: "push",
    branch: "main",
    head_sha: releaseSha,
    per_page: "100",
  });
  const body = await fetchJson(token, repository, `/actions/workflows/${workflowId}/runs?${query}`);
  if (!body || !Array.isArray(body.workflow_runs)) throw new Error("GitHub Actions API-response is ongeldig");
  return body.workflow_runs;
}

async function main() {
  const token = required(process.env, "GITHUB_TOKEN");
  const repository = required(process.env, "GITHUB_REPOSITORY");
  const releaseSha = required(process.env, "RELEASE_SHA");
  if (!/^[a-f0-9]{40}$/u.test(releaseSha)) throw new Error("RELEASE_SHA is ongeldig");
  if (!/^[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,99})\/[A-Za-z0-9](?:[A-Za-z0-9_.-]{0,99})$/u.test(repository)) {
    throw new Error("GITHUB_REPOSITORY is ongeldig");
  }

  const workflow = await fetchWorkflow(token, repository);
  const deadline = Date.now() + 55 * 60_000;
  while (Date.now() < deadline) {
    const selected = selectCiState(
      await fetchRuns(token, repository, workflow.id, releaseSha),
      releaseSha,
      repository,
      workflow.id,
    );
    if (selected.state === "success") {
      const run = validateCiRun(
        await fetchJson(token, repository, `/actions/runs/${selected.runId}`),
        {
          runId: selected.runId,
          workflowId: workflow.id,
          releaseSha,
          repository,
        },
      );
      const jobs = await fetchJson(
        token,
        repository,
        `/actions/runs/${run.id}/jobs?filter=latest&per_page=100`,
      );
      validateCiJobs(jobs.jobs);
      process.stdout.write("Volledige CI is groen voor exact de release-SHA.\n");
      return;
    }
    if (selected.state === "failed") throw new Error("Volledige CI is rood of geannuleerd voor de release-SHA");
    await new Promise((resolve) => setTimeout(resolve, 15_000));
  }
  throw new Error("Volledige CI werd niet tijdig groen voor de release-SHA");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : "CI-gate kon niet worden gecontroleerd"}\n`);
    process.exitCode = 1;
  });
}
