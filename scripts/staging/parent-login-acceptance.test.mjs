import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  databaseTargetFromEnvironment,
  fixtureDigest,
  fixtureIdentity,
  modeFromEnvironment,
  recipientFromEnvironment,
  runAcceptance,
  stableFailureCode,
  targetFromEnvironment,
  validateEvidence,
} from "./parent-login-acceptance.mjs";

const REF = "dxbdjtbyghsovlrdcwcr";
const base = {
  ARTIFACT_DIGEST: `sha256:${"b".repeat(64)}`,
  NEXT_PUBLIC_SUPABASE_URL: `https://${REF}.supabase.co`,
  PARENT_TOKEN_PEPPER: "staging-parent-login-contract-pepper-long-enough",
  RELEASE_SHA: "a".repeat(40),
  STAGING_ACCEPTANCE_RECIPIENT: "acceptance+parent-login@example.invalid",
  STAGING_ACCEPTANCE_RUN_ID: "12345-2",
  STAGING_BASE_URL: "https://duindorpsv.dgwebservices.nl",
  STAGING_DEPLOY_RUN_ID: "98765",
  STAGING_PARENT_LOGIN_ACCEPTANCE_ENABLED: "true",
  SUPABASE_DB_URL: `postgresql://postgres.${REF}:secret@aws-0-eu-central-1.pooler.supabase.com:6543/postgres?sslmode=require`,
  SUPABASE_SERVICE_ROLE_KEY: "staging-service-role-test-key",
  SUPABASE_PROJECT_REF: REF,
};

function evidence(environment, cleanupComplete = false) {
  const target = targetFromEnvironment(environment);
  return {
    cleanupComplete,
    codeConsumesLink: true,
    controlCenterLoaded: true,
    directGetCredentialFree: true,
    fixtureDigest: fixtureDigest(
      target,
      recipientFromEnvironment(environment),
      environment.PARENT_TOKEN_PEPPER,
    ),
    linkConsumesCode: true,
    linkReplayRejected: true,
    mailV2RegressionPassed: true,
    recipientFailureGlobalHealthHealthy: true,
    releaseSha: target.releaseSha,
    resendReusedChallenge: true,
    schemaVersion: 1,
    smtpAcceptanceNotDelivered: true,
    staffCredentialExposureCount: 0,
    supportAuthorizationPassed: true,
  };
}

describe("parent-login staging acceptance contract", () => {
  it("bindt de harness aan exact staging, exact artifact en een expliciete gate", () => {
    expect(targetFromEnvironment(base).runId).toBe("12345-2");
    for (const change of [
      { STAGING_BASE_URL: "https://duindorp.dgwebservices.nl" },
      { SUPABASE_PROJECT_REF: "wobcbufmmputydtzemyu" },
      { RELEASE_SHA: "main" },
      { ARTIFACT_DIGEST: "sha256:short" },
      { STAGING_DEPLOY_RUN_ID: "latest" },
      { STAGING_ACCEPTANCE_RUN_ID: "12345" },
      { STAGING_PARENT_LOGIN_ACCEPTANCE_ENABLED: "false" },
    ]) expect(() => targetFromEnvironment({ ...base, ...change })).toThrow();
  });

  it("weigert niet-TLS, vreemde databasehosts en multi-recipient invoer", () => {
    expect(databaseTargetFromEnvironment(base)).toContain(REF);
    for (const url of [
      `postgresql://postgres.${REF}:secret@evil.invalid:6543/postgres?sslmode=require`,
      `postgresql://postgres.${REF}:secret@aws-0-eu-central-1.pooler.supabase.com:6543/postgres?sslmode=disable`,
      `postgresql://postgres.${REF}:secret@aws-0-eu-central-1.pooler.supabase.com:6543/postgres?sslmode=require&host=evil.invalid`,
    ]) expect(() => databaseTargetFromEnvironment({ SUPABASE_DB_URL: url })).toThrow();
    expect(() => recipientFromEnvironment({ STAGING_ACCEPTANCE_RECIPIENT: "a@example.invalid,b@example.invalid" })).toThrow("STAGING_ACCEPTANCE_RECIPIENT_INVALID");
  });

  it("heeft exclusieve normal, cleanup en verify modi", () => {
    expect(modeFromEnvironment({})).toBe("normal");
    expect(modeFromEnvironment({ CLEANUP_ONLY: "1" })).toBe("cleanup");
    expect(modeFromEnvironment({ VERIFY_ONLY: "1" })).toBe("verify");
    expect(() => modeFromEnvironment({ CLEANUP_ONLY: "1", VERIFY_ONLY: "1" })).toThrow("STAGING_ACCEPTANCE_MODE_INVALID");
  });

  it("stuurt mutaties door dezelfde origin- en CSRF-grens als een browser", async () => {
    const source = await readFile(new URL("./parent-login-acceptance.mjs", import.meta.url), "utf8");
    expect(source).toContain('"Sec-Fetch-Site": "same-origin"');
    expect(source).toContain('"X-Duindorp-CSRF": "same-origin"');
    expect(source).toContain("Origin: target.baseUrl");
  });

  it("start de harness met TypeScript-stripping en de repository-aliasresolver", async () => {
    const repositoryRoot = fileURLToPath(new URL("../../", import.meta.url));
    const harness = fileURLToPath(new URL("./parent-login-acceptance.mjs", import.meta.url));
    const loader = fileURLToPath(new URL("./typescript-path-alias-loader.mjs", import.meta.url));
    const result = spawnSync(process.execPath, [
      "--experimental-strip-types",
      "--import",
      loader,
      harness,
    ], {
      cwd: repositoryRoot,
      encoding: "utf8",
      env: { ...process.env, STAGING_BASE_URL: "" },
    });
    expect(result.status).toBe(1);
    expect(result.stderr).toContain("MISSING_STAGING_BASE_URL");
    expect(result.stderr).not.toContain("ERR_MODULE_NOT_FOUND");

    const workflow = await readFile(
      new URL("../../.github/workflows/staging-parent-login-acceptance.yml", import.meta.url),
      "utf8",
    );
    expect(workflow.match(/--experimental-strip-types/gu)).toHaveLength(3);
    expect(workflow.match(/--import \.\/scripts\/staging\/typescript-path-alias-loader\.mjs/gu)).toHaveLength(3);
    expect(workflow.match(/typescript-path-alias-loader\.mjs/gu)).toHaveLength(3);
    expect(workflow).toContain("EMAIL_PROVIDER: ${{ vars.EMAIL_PROVIDER || 'smtp' }}");
    expect(workflow).toContain("SMTP_PASSWORD: ${{ secrets.SMTP_PASSWORD }}");
    expect(workflow).toContain("SENDGRID_API_KEY: ${{ secrets.SENDGRID_API_KEY }}");
  });

  it("maakt een run- en releasegebonden digest zonder ontvanger in evidence", () => {
    const target = targetFromEnvironment(base);
    const first = fixtureDigest(target, recipientFromEnvironment(base), base.PARENT_TOKEN_PEPPER);
    const second = fixtureDigest({ ...target, runId: "12346-1" }, recipientFromEnvironment(base), base.PARENT_TOKEN_PEPPER);
    const retry = fixtureDigest({ ...target, runId: "12345-3" }, recipientFromEnvironment(base), base.PARENT_TOKEN_PEPPER);
    expect(first).toMatch(/^[a-f0-9]{64}$/u);
    expect(first).not.toBe(second);
    expect(first).toBe(retry);
    expect(first).not.toBe(fixtureDigest(
      target,
      recipientFromEnvironment(base),
      `${base.PARENT_TOKEN_PEPPER}-rotated`,
    ));
    expect(JSON.stringify(evidence(base))).not.toContain(base.STAGING_ACCEPTANCE_RECIPIENT);
  });

  it("leidt run-unieke niet-PII fixture-identiteiten deterministisch af", () => {
    const digest = fixtureDigest(
      targetFromEnvironment(base),
      recipientFromEnvironment(base),
      base.PARENT_TOKEN_PEPPER,
    );
    const identity = fixtureIdentity(digest);
    expect(identity).toEqual(fixtureIdentity(digest));
    expect(identity.memberId).toMatch(/^[a-f0-9-]{36}$/u);
    expect(identity.grantId).not.toBe(identity.memberId);
    expect(identity.parentAccountId).not.toBe(identity.memberId);
    expect(identity.staffUserId).not.toBe(identity.memberId);
    expect(identity.relationNumber).toMatch(/^OTP-STG-[A-F0-9]{12}$/u);
    expect(JSON.stringify(identity)).not.toContain(
      base.STAGING_ACCEPTANCE_RECIPIENT,
    );
  });

  it("weigert extra evidencevelden, credentialexposure en onvolledige eindstatus", () => {
    const target = targetFromEnvironment(base);
    expect(() => validateEvidence({ ...evidence(base), recipient: base.STAGING_ACCEPTANCE_RECIPIENT }, target)).toThrow("STAGING_EVIDENCE_SHAPE_INVALID");
    expect(() => validateEvidence({ ...evidence(base), staffCredentialExposureCount: 1 }, target)).toThrow("STAGING_EVIDENCE_VALUE_INVALID");
    expect(() => validateEvidence(evidence(base), target, { requireCleanup: true })).toThrow("STAGING_EVIDENCE_VALUE_INVALID");
    expect(validateEvidence(evidence(base, true), target, { requireCleanup: true }).cleanupComplete).toBe(true);
  });

  it("doorloopt normal, always-cleanup en verify zonder state of PII te publiceren", async () => {
    const directory = await mkdtemp(join(tmpdir(), "parent-login-acceptance-"));
    const path = join(directory, "evidence.json");
    const environment = { ...base, EVIDENCE_PATH: path };
    const events = [];
    const dependencies = {
      startBoundary: async () => "2026-08-21 21:00:00+00",
      run: async (context) => {
        events.push("normal");
        return {
          evidence: evidence(environment),
          state: { challengeIds: ["11111111-1111-4111-8111-111111111111"], fixtureDigest: context.fixtureDigest, startedAt: context.startedAt },
        };
      },
      cleanup: async () => { events.push("cleanup"); return true; },
      verifyCleanup: async () => { events.push("verify"); return true; },
    };
    try {
      await runAcceptance(environment, dependencies);
      await runAcceptance({ ...environment, CLEANUP_ONLY: "1" }, dependencies);
      await runAcceptance({ ...environment, VERIFY_ONLY: "1" }, dependencies);
      expect(events).toEqual(["normal", "cleanup", "verify"]);
      const finalEvidence = JSON.parse(await readFile(path, "utf8"));
      expect(finalEvidence.cleanupComplete).toBe(true);
      expect(JSON.stringify(finalEvidence)).not.toContain(base.STAGING_ACCEPTANCE_RECIPIENT);
      await expect(readFile(`${path}.state`, "utf8")).rejects.toThrow();
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("legt cleanup-state vast voordat een muterende normal-run kan falen", async () => {
    const directory = await mkdtemp(join(tmpdir(), "parent-login-failure-"));
    const path = join(directory, "evidence.json");
    const environment = { ...base, EVIDENCE_PATH: path };
    let cleanedState;
    try {
      await expect(runAcceptance(environment, {
        startBoundary: async () => "2026-08-21 21:00:00+00",
        run: async (context) => {
          await context.recordState(["22222222-2222-4222-8222-222222222222"]);
          throw new Error("LINK_CONSUMPTION_FAILED");
        },
      })).rejects.toThrow("LINK_CONSUMPTION_FAILED");
      await runAcceptance({ ...environment, CLEANUP_ONLY: "1" }, {
        cleanup: async (_context, state) => { cleanedState = state; },
      });
      expect(cleanedState.challengeIds).toEqual([
        "22222222-2222-4222-8222-222222222222",
      ]);
      expect(JSON.stringify(cleanedState)).not.toContain(base.STAGING_ACCEPTANCE_RECIPIENT);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("sluit bij cleanup alleen challenges die door de eigen run zijn gemaakt", async () => {
    const source = await readFile(
      new URL("./parent-login-acceptance.mjs", import.meta.url),
      "utf8",
    );
    expect(source).toContain("set closed_at = statement_timestamp()");
    expect(source).toContain('runPsql(databaseUrl, "select clock_timestamp();")');
    expect(source).toContain("--no-psqlrc --quiet --tuples-only");
    expect(source).toContain("insert into app.members(");
    expect(source).toContain("insert into app.staff_profiles(");
    expect(source).toContain("private.parent_account_has_portal_access(account.id)");
    expect(source).toContain("grant select on table probe_context to authenticated");
    expect(source.match(/perform set_config\(/gu)).toHaveLength(3);
    expect(source).toContain("delete from private.parent_portal_grants");
    expect(source).toContain("delete from app.staff_profiles");
    expect(source).not.toContain("delete from private.rate_limit_events");
    expect(source).toContain("staging.parent_login.acceptance.challenge_owned");
    expect(source).toContain("STAGING_PREEXISTING_CHALLENGE_REUSED");
    expect(source).toContain("X-Duindorp-Staging-Challenge-Id");
    expect(source).toContain("X-Duindorp-Staging-Challenge-Proof");
    expect(source).toContain("recordChallengeOwnership(context, firstProposal)");
    expect(source).toContain("recordChallengeOwnership(context, replacementProposal)");
    expect(source.indexOf("recordChallengeOwnership(context, firstProposal)")).toBeLessThan(
      source.indexOf("const first = await requestChallenge("),
    );
    expect(source.indexOf("recordChallengeOwnership(context, replacementProposal)")).toBeLessThan(
      source.indexOf("const replacementCookie = await prepareSupportReplacement("),
    );
    expect(source).toContain("session_row.acceptance_correlation_hash");
    expect(source).toContain("prepare_parent_otp_support_delivery_v1");
    expect(source).toContain("assertParentSession(context, firstProposal)");
    expect(source).toContain("assertParentSession(context, replacementProposal)");
    expect(source).toContain("{ email: context.recipient }");
    expect(source).not.toContain("{ resend: true, forceNew: true }");
    expect(source).toContain('const workflowRunId = target.runId.split("-", 1)[0]');
  });

  it("maakt onverwachte fouten PII-vrij en behoudt vaste codes", () => {
    expect(stableFailureCode(new Error("LINK_REPLAY_ACCEPTED"))).toBe("LINK_REPLAY_ACCEPTED");
    expect(stableFailureCode(new Error("address parent@example.invalid"))).toBe("PARENT_LOGIN_ACCEPTANCE_FAILED");
    expect(stableFailureCode("plain")).toBe("PARENT_LOGIN_ACCEPTANCE_FAILED");
  });
});
