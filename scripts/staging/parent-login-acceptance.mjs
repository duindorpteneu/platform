import crypto from "node:crypto";
import { spawnSync } from "node:child_process";
import { chmod, readFile, unlink, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { createClient } from "@supabase/supabase-js";
import { parentOtpV3PreparationSchema } from "../../src/lib/mail-v2-contract.ts";
import {
  deriveParentCode,
  deriveParentDirectCredential,
  hashParentSecret,
  openParentChallengeContext,
  sealParentChallengeContext,
} from "../../src/server/auth/parent.ts";
import { deliverPreparedParentOtpV3 } from "../../src/server/email/otp-delivery.ts";
import { requireExplicitDatabaseTls } from "./require-database-tls.mjs";

const STAGING_ORIGIN = "https://duindorpsv.dgwebservices.nl";
const STAGING_REF = "dxbdjtbyghsovlrdcwcr";
const POSTGRES_IMAGE = "public.ecr.aws/supabase/postgres:17.6.1.143@sha256:80d7b27c3e8d77cfa7226eee9508671796da214781ff15a35b3670d7ad5ee453";
const EVIDENCE_KEYS = [
  "cleanupComplete",
  "codeConsumesLink",
  "controlCenterLoaded",
  "directGetCredentialFree",
  "fixtureDigest",
  "linkConsumesCode",
  "linkReplayRejected",
  "mailV2RegressionPassed",
  "recipientFailureGlobalHealthHealthy",
  "releaseSha",
  "resendReusedChallenge",
  "schemaVersion",
  "smtpAcceptanceNotDelivered",
  "staffCredentialExposureCount",
  "supportAuthorizationPassed",
];
const BOOLEAN_EVIDENCE_KEYS = EVIDENCE_KEYS.filter((key) => ![
  "fixtureDigest", "releaseSha", "schemaVersion", "staffCredentialExposureCount",
].includes(key));

function required(environment, name) {
  const value = environment[name]?.trim() ?? "";
  if (!value || /[\r\n\0]/u.test(value)) throw new Error(`MISSING_${name}`);
  return value;
}

export function targetFromEnvironment(environment = process.env) {
  const baseUrl = required(environment, "STAGING_BASE_URL");
  const projectRef = required(environment, "SUPABASE_PROJECT_REF");
  const releaseSha = required(environment, "RELEASE_SHA");
  const artifactDigest = required(environment, "ARTIFACT_DIGEST");
  const stagingDeployRunId = required(environment, "STAGING_DEPLOY_RUN_ID");
  const runId = required(environment, "STAGING_ACCEPTANCE_RUN_ID");
  if (baseUrl !== STAGING_ORIGIN || projectRef !== STAGING_REF) {
    throw new Error("STAGING_TARGET_INVALID");
  }
  if (environment.STAGING_PARENT_LOGIN_ACCEPTANCE_ENABLED !== "true") {
    throw new Error("STAGING_ACCEPTANCE_GATE_CLOSED");
  }
  if (!/^[a-f0-9]{40}$/u.test(releaseSha)) throw new Error("RELEASE_SHA_INVALID");
  if (!/^sha256:[a-f0-9]{64}$/u.test(artifactDigest)) {
    throw new Error("ARTIFACT_DIGEST_INVALID");
  }
  if (!/^[1-9][0-9]{0,19}$/u.test(stagingDeployRunId)) {
    throw new Error("STAGING_DEPLOY_RUN_ID_INVALID");
  }
  if (!/^[1-9][0-9]{0,19}-[1-9][0-9]{0,9}$/u.test(runId)) {
    throw new Error("STAGING_ACCEPTANCE_RUN_ID_INVALID");
  }
  return { artifactDigest, baseUrl, projectRef, releaseSha, runId, stagingDeployRunId };
}

export function databaseTargetFromEnvironment(environment = process.env) {
  const databaseUrl = requireExplicitDatabaseTls(required(environment, "SUPABASE_DB_URL"));
  let parsed;
  try {
    parsed = new URL(databaseUrl);
  } catch {
    throw new Error("STAGING_DATABASE_TARGET_INVALID");
  }
  const keys = [...new Set(parsed.searchParams.keys())];
  const direct = parsed.hostname === `db.${STAGING_REF}.supabase.co`
    && decodeURIComponent(parsed.username) === "postgres"
    && (parsed.port === "" || parsed.port === "5432");
  const pooler = parsed.hostname.endsWith(".pooler.supabase.com")
    && decodeURIComponent(parsed.username) === `postgres.${STAGING_REF}`
    && ["5432", "6543"].includes(parsed.port);
  if (!parsed.password || parsed.pathname !== "/postgres" || (!direct && !pooler)
    || keys.some((key) => !["connect_timeout", "sslmode"].includes(key))
    || keys.some((key) => parsed.searchParams.getAll(key).length !== 1)
    || !["require", "verify-ca", "verify-full"].includes(parsed.searchParams.get("sslmode"))) {
    throw new Error("STAGING_DATABASE_TARGET_INVALID");
  }
  return databaseUrl;
}

export function recipientFromEnvironment(environment = process.env) {
  const recipient = required(environment, "STAGING_ACCEPTANCE_RECIPIENT").toLowerCase();
  if (recipient.length > 254
    || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(recipient)
    || recipient.includes(",") || recipient.includes(";")) {
    throw new Error("STAGING_ACCEPTANCE_RECIPIENT_INVALID");
  }
  return recipient;
}

export function modeFromEnvironment(environment = process.env) {
  const cleanup = environment.CLEANUP_ONLY === "1";
  const verify = environment.VERIFY_ONLY === "1";
  if (cleanup && verify) throw new Error("STAGING_ACCEPTANCE_MODE_INVALID");
  return cleanup ? "cleanup" : verify ? "verify" : "normal";
}

export function fixtureDigest(target, recipient, secret) {
  if (typeof secret !== "string" || secret.length < 32) {
    throw new Error("STAGING_FIXTURE_SECRET_INVALID");
  }
  const workflowRunId = target.runId.split("-", 1)[0];
  return crypto.createHmac("sha256", secret).update([
    "parent-login-acceptance:v1", target.releaseSha, target.artifactDigest,
    target.stagingDeployRunId, workflowRunId, recipient,
  ].join("\0"), "utf8").digest("hex");
}

function deterministicFixtureUuid(seed, domain) {
  const bytes = crypto.createHash("sha256")
    .update(`parent-login-acceptance:${domain}\0${seed}`, "utf8")
    .digest()
    .subarray(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export function fixtureIdentity(digest) {
  if (!/^[a-f0-9]{64}$/u.test(digest)) {
    throw new Error("STAGING_FIXTURE_DIGEST_INVALID");
  }
  return {
    grantId: deterministicFixtureUuid(digest, "grant"),
    memberId: deterministicFixtureUuid(digest, "member"),
    parentAccountId: deterministicFixtureUuid(digest, "parent-account"),
    relationNumber: `OTP-STG-${digest.slice(0, 12).toUpperCase()}`,
    staffUserId: deterministicFixtureUuid(digest, "staff-user"),
  };
}

export function validateEvidence(value, target, { requireCleanup = false } = {}) {
  if (!value || typeof value !== "object" || Array.isArray(value)
    || JSON.stringify(Object.keys(value).sort()) !== JSON.stringify([...EVIDENCE_KEYS].sort())) {
    throw new Error("STAGING_EVIDENCE_SHAPE_INVALID");
  }
  if (value.schemaVersion !== 1 || value.releaseSha !== target.releaseSha
    || !/^[a-f0-9]{64}$/u.test(value.fixtureDigest)
    || value.staffCredentialExposureCount !== 0
    || BOOLEAN_EVIDENCE_KEYS.some((key) => typeof value[key] !== "boolean")
    || (requireCleanup && BOOLEAN_EVIDENCE_KEYS.some((key) => value[key] !== true))) {
    throw new Error("STAGING_EVIDENCE_VALUE_INVALID");
  }
  return value;
}

export function stableFailureCode(error) {
  const message = error instanceof Error ? error.message : "";
  return /^[A-Z][A-Z0-9_]{2,79}$/u.test(message)
    ? message
    : "PARENT_LOGIN_ACCEPTANCE_FAILED";
}

function statePath(evidencePath) {
  return `${evidencePath}.state`;
}

async function writePrivateJson(path, value) {
  await writeFile(path, `${JSON.stringify(value)}\n`, { encoding: "utf8", mode: 0o600 });
  await chmod(path, 0o600);
}

async function readJson(path, code) {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch {
    throw new Error(code);
  }
}

function cookieValue(response, name) {
  const values = typeof response.headers.getSetCookie === "function"
    ? response.headers.getSetCookie()
    : [response.headers.get("set-cookie") ?? ""];
  for (const value of values) {
    const match = value.match(new RegExp(`(?:^|[,;]\\s*)${name}=([^;]*)`, "u"));
    if (match) return match[1];
  }
  throw new Error("PARENT_CHALLENGE_COOKIE_MISSING");
}

async function postJson(target, path, body, cookie, acceptance) {
  const response = await fetch(`${target.baseUrl}${path}`, {
    method: "POST",
    redirect: "manual",
    signal: AbortSignal.timeout(20_000),
    headers: {
      "Content-Type": "application/json",
      Origin: target.baseUrl,
      "Sec-Fetch-Site": "same-origin",
      "X-Duindorp-CSRF": "same-origin",
      ...(cookie ? { Cookie: `duindorp_parent_challenge=${cookie}` } : {}),
      ...(acceptance ? {
        "X-Duindorp-Staging-Challenge-Id": acceptance.challengeId,
        "X-Duindorp-Staging-Challenge-Proof": acceptance.proof,
        "X-Duindorp-Staging-Fixture-Digest": acceptance.fixtureDigest,
        "X-Duindorp-Staging-Session-Id": acceptance.sessionId,
        "X-Duindorp-Staging-Session-Proof": acceptance.sessionProof,
      } : {}),
    },
    body: JSON.stringify(body),
  });
  return response;
}

async function requestChallenge(target, body, cookie, acceptance) {
  const response = await postJson(
    target,
    "/api/parent-auth/request-code",
    body,
    cookie,
    acceptance,
  );
  if (response.status !== 202) throw new Error("PARENT_CHALLENGE_REQUEST_FAILED");
  const nextCookie = cookieValue(response, "duindorp_parent_challenge");
  const context = openParentChallengeContext(nextCookie);
  if (!context) throw new Error("PARENT_CHALLENGE_CONTEXT_INVALID");
  return { context, cookie: nextCookie };
}

function requireVerificationStatus(response, expectedStatus, failureCode) {
  if (response.status === 503) {
    throw new Error("PARENT_VERIFICATION_UNAVAILABLE");
  }
  if (response.status !== expectedStatus) {
    throw new Error(failureCode);
  }
}

function challengeProposal(context) {
  const challengeId = crypto.randomUUID();
  const sessionId = crypto.randomUUID();
  return {
    challengeId,
    fixtureDigest: context.fixtureDigest,
    proof: crypto.createHmac("sha256", context.fixtureSecret).update(
      `parent-login-staging-challenge:v1\0${context.fixtureDigest}\0${challengeId}`,
      "utf8",
    ).digest("hex"),
    sessionCorrelationHash: crypto.createHmac("sha256", context.fixtureSecret).update(
      `parent-login-staging-session-correlation:v1\0${context.fixtureDigest}\0${sessionId}`,
      "utf8",
    ).digest("hex"),
    sessionId,
    sessionProof: crypto.createHmac("sha256", context.fixtureSecret).update(
      `parent-login-staging-session:v1\0${context.fixtureDigest}\0${sessionId}`,
      "utf8",
    ).digest("hex"),
  };
}

async function defaultRun(context, helpers = {}) {
  const wait = helpers.wait ?? ((milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds)));
  const directMarker = `v1.00000000-0000-4000-8000-000000000000.${"a".repeat(43)}`;
  const directPage = await fetch(`${context.target.baseUrl}/login/direct#${directMarker}`, {
    redirect: "manual", signal: AbortSignal.timeout(20_000),
  });
  const directBody = await directPage.text();
  if (!directPage.ok || directPage.url.includes("#") || directBody.includes(directMarker)) {
    throw new Error("DIRECT_GET_CREDENTIAL_EXPOSURE");
  }

  prepareParentFixture(context);

  const firstProposal = challengeProposal(context);
  recordChallengeOwnership(context, firstProposal);
  await context.recordState([firstProposal.challengeId]);
  const first = await requestChallenge(
    context.target,
    { email: context.recipient },
    undefined,
    firstProposal,
  );
  if (first.context.challengeId !== firstProposal.challengeId) {
    throw new Error("STAGING_PREEXISTING_CHALLENGE_REUSED");
  }
  await wait(91_000);
  const resent = await requestChallenge(context.target, { resend: true }, first.cookie);
  if (resent.context.challengeId !== first.context.challengeId) {
    throw new Error("RESEND_REPLACED_CHALLENGE");
  }
  const firstCode = deriveParentCode(first.context.challengeId);
  const firstDirect = deriveParentDirectCredential(first.context.challengeId);
  const codeResponse = await postJson(
    context.target,
    "/api/parent-auth/verify-code",
    { code: firstCode },
    resent.cookie,
    firstProposal,
  );
  if (codeResponse.status === 401) {
    throw new Error("CODE_CONSUMPTION_REJECTED");
  }
  if (codeResponse.status === 429) {
    throw new Error("CODE_CONSUMPTION_RATE_LIMITED");
  }
  requireVerificationStatus(codeResponse, 200, "CODE_CONSUMPTION_FAILED");
  assertParentSession(context, firstProposal);
  const consumedLink = await postJson(context.target, "/api/parent-auth/verify-direct", { credential: firstDirect });
  requireVerificationStatus(consumedLink, 401, "CODE_DID_NOT_CONSUME_LINK");

  const replacementProposal = challengeProposal(context);
  recordChallengeOwnership(context, replacementProposal);
  await context.recordState([
    first.context.challengeId,
    replacementProposal.challengeId,
  ]);
  const replacementCookie = await prepareSupportReplacement(
    context,
    replacementProposal,
  );
  const secondCode = deriveParentCode(replacementProposal.challengeId);
  const secondDirect = deriveParentDirectCredential(replacementProposal.challengeId);
  const linkResponse = await postJson(
    context.target,
    "/api/parent-auth/verify-direct",
    { credential: secondDirect },
    undefined,
    replacementProposal,
  );
  requireVerificationStatus(linkResponse, 200, "LINK_CONSUMPTION_FAILED");
  assertParentSession(context, replacementProposal);
  const consumedCode = await postJson(
    context.target,
    "/api/parent-auth/verify-code",
    { code: secondCode },
    replacementCookie,
  );
  requireVerificationStatus(consumedCode, 401, "LINK_DID_NOT_CONSUME_CODE");
  const replay = await postJson(context.target, "/api/parent-auth/verify-direct", { credential: secondDirect });
  requireVerificationStatus(replay, 401, "LINK_REPLAY_ACCEPTED");

  const database = databaseContractProbe(context);
  return {
    evidence: {
      cleanupComplete: false,
      codeConsumesLink: true,
      controlCenterLoaded: database.controlCenterLoaded,
      directGetCredentialFree: true,
      fixtureDigest: context.fixtureDigest,
      linkConsumesCode: true,
      linkReplayRejected: true,
      mailV2RegressionPassed: database.mailV2RegressionPassed,
      recipientFailureGlobalHealthHealthy: database.recipientFailureGlobalHealthHealthy,
      releaseSha: context.target.releaseSha,
      resendReusedChallenge: true,
      schemaVersion: 1,
      smtpAcceptanceNotDelivered: database.smtpAcceptanceNotDelivered,
      staffCredentialExposureCount: database.staffCredentialExposureCount,
      supportAuthorizationPassed: database.supportAuthorizationPassed,
    },
    state: {
      challengeIds: [first.context.challengeId, replacementProposal.challengeId],
      fixtureDigest: context.fixtureDigest,
      grantId: context.fixture.grantId,
      memberId: context.fixture.memberId,
      relationNumber: context.fixture.relationNumber,
      staffUserId: context.fixture.staffUserId,
      startedAt: context.startedAt,
    },
  };
}

function runPsql(databaseUrl, statement, variables = {}) {
  const environment = { ...process.env, TARGET_DB_URL: databaseUrl };
  const args = [
    "run", "--rm", "--interactive", "--read-only", "--cap-drop=ALL",
    "--security-opt", "no-new-privileges:true", "--tmpfs", "/tmp:rw,noexec,nosuid,size=16m",
    "--env", "TARGET_DB_URL",
  ];
  for (const [name, value] of Object.entries(variables)) {
    environment[name] = value;
    args.push("--env", name);
  }
  args.push("--entrypoint", "sh", POSTGRES_IMAGE, "-ceu",
    `psql \"$TARGET_DB_URL\" --no-psqlrc --quiet --tuples-only --no-align --set=ON_ERROR_STOP=1 ${Object.keys(variables).map((name) => `--set=${name.toLowerCase()}=\"$${name}\"`).join(" ")}`);
  const result = spawnSync("docker", args, {
    env: environment, input: statement, encoding: "utf8",
    stdio: ["pipe", "pipe", "ignore"], timeout: 60_000,
  });
  if (result.status !== 0) throw new Error("STAGING_DATABASE_PROBE_FAILED");
  return result.stdout.trim();
}

function prepareParentFixture(context) {
  const prepared = runPsql(context.databaseUrl, `
    begin;
    delete from private.parent_sessions session_row
    using private.parent_accounts account
    where account.email_normalized = lower(:'recipient')
      and session_row.parent_account_id = account.id
      and exists (
        select 1
        from app.audit_logs owned
        where owned.action = 'staging.parent_login.acceptance.challenge_owned'
          and owned.metadata->>'fixtureDigest' = :'fixture_digest'
          and owned.metadata->>'sessionCorrelationHash'
            = session_row.acceptance_correlation_hash
      );
    update private.parent_otp_challenges challenge
    set closed_at = statement_timestamp(),
        close_reason = 'support_reset',
        used_at = coalesce(challenge.used_at, statement_timestamp())
    where challenge.closed_at is null
      and exists (
        select 1 from app.audit_logs owned
        where owned.action = 'staging.parent_login.acceptance.challenge_owned'
          and owned.entity_id = challenge.id
          and owned.metadata->>'fixtureDigest' = :'fixture_digest'
      );
    delete from private.parent_portal_grants grant_row
    where grant_row.id = :'grant_id'::uuid;
    delete from app.members member
    where member.id = :'member_id'::uuid
      and member.relation_number = :'relation_number'
      and member.email = lower(:'recipient');
    delete from app.staff_profiles profile
    where profile.auth_user_id = :'staff_user_id'::uuid
      and profile.display_name = 'Staging ouderloginacceptatie'
      and profile.role = 'beheerder';
    insert into private.parent_accounts(id, email_normalized)
    values(:'parent_account_id'::uuid, lower(:'recipient'))
    on conflict (email_normalized) do nothing;
    insert into app.staff_profiles(
      auth_user_id, display_name, role, active
    ) values (
      :'staff_user_id'::uuid,
      'Staging ouderloginacceptatie',
      'beheerder',
      true
    );
    insert into app.members(
      id, relation_number, first_name, last_name, email, team
    ) values (
      :'member_id'::uuid,
      :'relation_number',
      'Staging',
      'Ouderloginacceptatie',
      lower(:'recipient'),
      'ACCEPTATIE'
    );
    insert into private.parent_portal_grants(
      id, member_season_id, email_normalized, parent_account_id,
      status, source, granted_by, granted_at
    )
    select
      :'grant_id'::uuid,
      member_season.id,
      lower(:'recipient'),
      account.id,
      'active',
      'administrator',
      :'staff_user_id'::uuid,
      statement_timestamp()
    from app.member_seasons member_season
    join private.parent_accounts account
      on account.email_normalized = lower(:'recipient')
    where member_season.member_id = :'member_id'::uuid
      and member_season.season_id = (
        select settings.active_season_id
        from app.app_settings settings
        where settings.id = true
      );
    select (
      exists(select 1 from app.members member
        where member.id = :'member_id'::uuid
          and member.relation_number = :'relation_number')
      and exists(select 1 from private.parent_portal_grants grant_row
        join private.parent_accounts account
          on account.id = grant_row.parent_account_id
        where grant_row.id = :'grant_id'::uuid
          and grant_row.status = 'active'
          and account.email_normalized = lower(:'recipient'))
      and exists(select 1 from private.parent_accounts account
        where account.email_normalized = lower(:'recipient')
          and private.parent_account_has_portal_access(account.id))
      and exists(select 1 from app.staff_profiles profile
        where profile.auth_user_id = :'staff_user_id'::uuid
          and profile.role = 'beheerder' and profile.active)
    )::int;
    commit;
  `, {
    FIXTURE_DIGEST: context.fixtureDigest,
    GRANT_ID: context.fixture.grantId,
    MEMBER_ID: context.fixture.memberId,
    PARENT_ACCOUNT_ID: context.fixture.parentAccountId,
    RECIPIENT: context.recipient,
    RELATION_NUMBER: context.fixture.relationNumber,
    STAFF_USER_ID: context.fixture.staffUserId,
  });
  if (prepared !== "1") throw new Error("STAGING_PARENT_FIXTURE_PREPARE_FAILED");
}

function recordChallengeOwnership(context, proposal) {
  const recorded = runPsql(context.databaseUrl, `
    insert into app.audit_logs(
      actor_user_id, action, entity_type, entity_id, metadata, correlation_id
    )
    select
      null,
      'staging.parent_login.acceptance.challenge_owned',
      'parent_otp_challenge',
      :'challenge_id'::uuid,
      jsonb_build_object(
        'fixtureDigest', :'fixture_digest',
        'sessionCorrelationHash', :'session_correlation_hash'
      ),
      :'correlation_id'::uuid
    where not exists (
      select 1 from app.audit_logs owned
      where owned.action = 'staging.parent_login.acceptance.challenge_owned'
        and owned.entity_id = :'challenge_id'::uuid
        and owned.metadata->>'fixtureDigest' = :'fixture_digest'
    );
    select count(*)
    from app.audit_logs owned
    where owned.action = 'staging.parent_login.acceptance.challenge_owned'
      and owned.entity_id = :'challenge_id'::uuid
      and owned.metadata->>'fixtureDigest' = :'fixture_digest';
  `, {
    CHALLENGE_ID: proposal.challengeId,
    CORRELATION_ID: context.fixture.grantId,
    FIXTURE_DIGEST: context.fixtureDigest,
    SESSION_CORRELATION_HASH: proposal.sessionCorrelationHash,
  });
  if (recorded !== "1") throw new Error("STAGING_CHALLENGE_OWNERSHIP_FAILED");
}

async function prepareSupportReplacement(context, proposal) {
  const requestId = crypto.randomUUID();
  const raw = runPsql(context.databaseUrl, `
    begin;
    create temporary table support_context on commit drop as
    select account.id parent_account_id, profile.auth_user_id
    from private.parent_accounts account
    join app.staff_profiles profile
      on profile.auth_user_id = :'staff_user_id'::uuid
      and profile.role = 'beheerder'
      and profile.active
    where account.email_normalized = lower(:'recipient');
    grant select on table support_context to authenticated;
    do $$
    begin
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object(
          'sub', (select auth_user_id from support_context),
          'aal', 'aal2'
        )::text,
        true
      );
    end;
    $$;
    set local role authenticated;
    select app.prepare_parent_otp_support_delivery_v1(
      (select parent_account_id from support_context),
      'resend',
      :'challenge_id'::uuid,
      :'code_hash',
      :'request_id'::uuid
    );
    commit;
  `, {
    CHALLENGE_ID: proposal.challengeId,
    CODE_HASH: hashParentSecret(deriveParentCode(proposal.challengeId)),
    RECIPIENT: context.recipient,
    REQUEST_ID: requestId,
    STAFF_USER_ID: context.fixture.staffUserId,
  });
  let decoded;
  try {
    decoded = JSON.parse(raw);
  } catch {
    throw new Error("STAGING_SUPPORT_PREPARATION_INVALID");
  }
  const preparation = parentOtpV3PreparationSchema.safeParse(decoded);
  if (!preparation.success || preparation.data.status !== "prepared") {
    throw new Error("STAGING_SUPPORT_PREPARATION_INVALID");
  }
  const delivery = await deliverPreparedParentOtpV3(
    context.admin,
    preparation.data,
    context.recipient,
    context.target.baseUrl,
  );
  if (delivery.outcome !== "provider_accepted") {
    throw new Error("STAGING_SUPPORT_DELIVERY_NOT_ACCEPTED");
  }
  if (preparation.data.challengeId !== proposal.challengeId
    || preparation.data.reused
    || preparation.data.supportRequestReused === true) {
    throw new Error("STAGING_PREEXISTING_CHALLENGE_REUSED");
  }
  return sealParentChallengeContext({
    version: 3,
    email: context.recipient,
    challengeId: preparation.data.challengeId,
    expiresAt: preparation.data.expiresAt,
    cooldownUntil: preparation.data.cooldownUntil,
  });
}

function assertParentSession(context, proposal) {
  const found = runPsql(context.databaseUrl, `
    select count(*)
    from private.parent_sessions session_row
    join private.parent_accounts account
      on account.id = session_row.parent_account_id
    where account.email_normalized = lower(:'recipient')
      and session_row.acceptance_correlation_hash = :'session_correlation_hash';
  `, {
    RECIPIENT: context.recipient,
    SESSION_CORRELATION_HASH: proposal.sessionCorrelationHash,
  });
  if (found !== "1") {
    throw new Error("STAGING_PARENT_SESSION_NOT_FOUND");
  }
}

function databaseContractProbe(context) {
  const result = runPsql(context.databaseUrl, `
    begin;
    create temporary table probe_context on commit drop as
    select account.id parent_account_id, profile.auth_user_id
    from private.parent_accounts account
    join app.staff_profiles profile
      on profile.auth_user_id = :'staff_user_id'::uuid
      and profile.role = 'beheerder'
      and profile.active
    where account.email_normalized = lower(:'recipient')
      and private.parent_account_has_portal_access(account.id);
    grant select on table probe_context to authenticated;
    create temporary table baseline_health on commit drop as
    select app.get_operational_health_v15(repeat('a', 64), 1, null, null) result;
    do $$
    begin
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object(
          'sub', (select auth_user_id from probe_context),
          'aal', 'aal2'
        )::text,
        true
      );
    end;
    $$;
    set local role authenticated;
    create temporary table support_snapshot on commit drop as
    select app.get_parent_otp_support_v1(
      (select parent_account_id from probe_context)
    ) result;
    create temporary table support_first on commit drop as
    select app.prepare_parent_otp_support_delivery_v1(
      (select parent_account_id from probe_context),
      'resend',
      gen_random_uuid(),
      repeat('7', 64),
      'a7300000-0000-4000-8000-000000000001'::uuid
    ) result;
    create temporary table support_second on commit drop as
    select app.prepare_parent_otp_support_delivery_v1(
      (select parent_account_id from probe_context),
      'resend',
      gen_random_uuid(),
      repeat('8', 64),
      'a7300000-0000-4000-8000-000000000002'::uuid
    ) result;
    reset role;
    create temporary table smtp_acceptance on commit drop as
    select app.complete_parent_otp_delivery_v2(
      (select (result->>'deliveryAttemptId')::uuid from support_first),
      'accepted',
      'staging-parent-login-acceptance',
      null,
      'smtp',
      'provider_accepted',
      '250',
      '2.0.0',
      false
    ) result;
    create temporary table recipient_failure on commit drop as
    select app.complete_parent_otp_delivery_v2(
      (select (result->>'deliveryAttemptId')::uuid from support_second),
      'provider_rejected',
      null,
      'smtp_550',
      'smtp',
      'permanent_rejection',
      '550',
      '5.1.1',
      true
    ) result;
    create temporary table after_health on commit drop as
    select app.get_operational_health_v15(repeat('a', 64), 1, null, null) result;
    do $$
    begin
      perform set_config(
        'request.jwt.claims',
        jsonb_build_object(
          'sub', (select auth_user_id from probe_context),
          'aal', 'aal2'
        )::text,
        true
      );
    end;
    $$;
    set local role authenticated;
    create temporary table control_center_snapshot on commit drop as
    select app.get_email_control_center_v1() result;
    reset role;
    select concat_ws(':',
      ((select count(*) = 1 from probe_context)
        and (select result->>'status' = 'prepared' from support_first)
        and (select result->>'status' = 'prepared' from support_second))::int,
      ((select not result ?| array['code','codeHash','credential','proof']
          from support_snapshot)
        and (select not result ?| array['code','codeHash','credential','proof']
          from support_first))::int,
      ((select result->>'feedbackCapability' = 'smtp_sync_only'
          from control_center_snapshot)
        and exists(
          select 1
          from control_center_snapshot snapshot,
            lateral jsonb_array_elements(snapshot.result->'recipients') recipient_row
          where recipient_row->>'email' = lower(:'recipient')
            and recipient_row ? 'lastProviderAcceptanceAt'
            and recipient_row ? 'lastProvenDeliveryAt'
        ))::int,
      ((select result #>> '{parentOtpDelivery,sendFailuresRecent}'
          from after_health)
        = (select result #>> '{parentOtpDelivery,sendFailuresRecent}'
          from baseline_health))::int,
      (exists(
        select 1
        from private.email_provider_sync_evidence evidence
        where evidence.parent_otp_delivery_attempt_id =
          (select (result->>'deliveryAttemptId')::uuid from support_first)
          and evidence.provider = 'smtp'
          and evidence.provider_state = 'provider_accepted'
          and not exists(
            select 1 from private.parent_otp_provider_events event
            where event.delivery_attempt_id =
              evidence.parent_otp_delivery_attempt_id
          )
      ))::int,
      (exists(select 1 from app.mail_templates where template_key = 'login_otp' and active)
        and exists(select 1 from app.mail_template_revisions revision
          where revision.template_key = 'login_otp'
            and revision.status = 'published'
            and revision.body_tiptap::text like '%otp_direct_login%'))::int);
    rollback;
  `, {
    RECIPIENT: context.recipient,
    STAFF_USER_ID: context.fixture.staffUserId,
  });
  if (!/^[01](?::[01]){5}$/u.test(result)) throw new Error("STAGING_DATABASE_PROBE_RESPONSE_INVALID");
  const flags = result.split(":").map((value) => value === "1");
  if (flags.some((value) => !value)) throw new Error("STAGING_DATABASE_CONTRACT_FAILED");
  return {
    supportAuthorizationPassed: flags[0], staffCredentialExposureCount: flags[1] ? 0 : 1,
    controlCenterLoaded: flags[2], recipientFailureGlobalHealthHealthy: flags[3],
    smtpAcceptanceNotDelivered: flags[4], mailV2RegressionPassed: flags[5],
  };
}

function databaseStartBoundary(databaseUrl) {
  const boundary = runPsql(databaseUrl, "select clock_timestamp();");
  if (Number.isNaN(Date.parse(boundary))) {
    throw new Error("STAGING_DATABASE_BOUNDARY_INVALID");
  }
  return boundary;
}

async function defaultCleanup(context, state) {
  if (!state || state.fixtureDigest !== context.fixtureDigest
    || !Array.isArray(state.challengeIds) || state.challengeIds.length > 4
    || state.challengeIds.some((id) => !/^[a-f0-9-]{36}$/u.test(id))
    || state.grantId !== context.fixture.grantId
    || state.memberId !== context.fixture.memberId
    || state.relationNumber !== context.fixture.relationNumber
    || state.staffUserId !== context.fixture.staffUserId
    || Number.isNaN(Date.parse(state.startedAt))) {
    throw new Error("STAGING_CLEANUP_STATE_INVALID");
  }
  const cleaned = runPsql(context.databaseUrl, `
    begin;
    delete from private.parent_sessions session_row
    using private.parent_accounts account
    where account.email_normalized = lower(:'recipient')
      and session_row.parent_account_id = account.id
      and exists (
        select 1
        from app.audit_logs owned
        where owned.action = 'staging.parent_login.acceptance.challenge_owned'
          and owned.metadata->>'fixtureDigest' = :'fixture_digest'
          and owned.metadata->>'sessionCorrelationHash'
            = session_row.acceptance_correlation_hash
      );
    update private.parent_otp_challenges challenge
    set closed_at = statement_timestamp(),
        close_reason = 'support_reset',
        used_at = coalesce(challenge.used_at, statement_timestamp())
    from private.parent_accounts account
    where account.email_normalized = lower(:'recipient')
      and challenge.parent_account_id = account.id
      and exists (
        select 1 from app.audit_logs owned
        where owned.action = 'staging.parent_login.acceptance.challenge_owned'
          and owned.entity_id = challenge.id
          and owned.metadata->>'fixtureDigest' = :'fixture_digest'
      )
      and challenge.closed_at is null;
    delete from private.parent_portal_grants grant_row
    where grant_row.id = :'grant_id'::uuid
      and grant_row.email_normalized = lower(:'recipient')
      and grant_row.member_season_id in (
        select member_season.id
        from app.member_seasons member_season
        where member_season.member_id = :'member_id'::uuid
      );
    delete from app.members member
    where member.id = :'member_id'::uuid
      and member.relation_number = :'relation_number'
      and member.email = lower(:'recipient');
    delete from app.staff_profiles profile
    where profile.auth_user_id = :'staff_user_id'::uuid
      and profile.display_name = 'Staging ouderloginacceptatie'
      and profile.role = 'beheerder';
    commit;
    select (
      not exists(select 1 from private.parent_sessions session_row
        join private.parent_accounts account on account.id = session_row.parent_account_id
        where account.email_normalized = lower(:'recipient')
          and exists (
            select 1
            from app.audit_logs owned
            where owned.action = 'staging.parent_login.acceptance.challenge_owned'
              and owned.metadata->>'fixtureDigest' = :'fixture_digest'
              and owned.metadata->>'sessionCorrelationHash'
                = session_row.acceptance_correlation_hash
          ))
      and not exists(select 1 from private.parent_otp_challenges challenge
        join private.parent_accounts account on account.id = challenge.parent_account_id
        where account.email_normalized = lower(:'recipient')
          and exists (
            select 1 from app.audit_logs owned
            where owned.action = 'staging.parent_login.acceptance.challenge_owned'
              and owned.entity_id = challenge.id
              and owned.metadata->>'fixtureDigest' = :'fixture_digest'
          )
          and challenge.closed_at is null)
      and not exists(select 1 from private.parent_portal_grants grant_row
        where grant_row.id = :'grant_id'::uuid)
      and not exists(select 1 from app.members member
        where member.id = :'member_id'::uuid)
      and not exists(select 1 from app.staff_profiles profile
        where profile.auth_user_id = :'staff_user_id'::uuid)
    )::int;
  `, {
    FIXTURE_DIGEST: state.fixtureDigest,
    GRANT_ID: state.grantId,
    MEMBER_ID: state.memberId,
    RECIPIENT: context.recipient,
    RELATION_NUMBER: state.relationNumber,
    STAFF_USER_ID: state.staffUserId,
  });
  if (cleaned !== "1") throw new Error("STAGING_FIXTURE_CLEANUP_FAILED");
  return true;
}

async function defaultVerifyCleanup(context, state) {
  return defaultCleanup(context, state);
}

export async function runAcceptance(environment = process.env, dependencies = {}) {
  const target = targetFromEnvironment(environment);
  const recipient = recipientFromEnvironment(environment);
  const databaseUrl = databaseTargetFromEnvironment(environment);
  const fixtureSecret = required(environment, "PARENT_TOKEN_PEPPER");
  const supabaseUrl = required(environment, "NEXT_PUBLIC_SUPABASE_URL");
  const serviceRoleKey = required(environment, "SUPABASE_SERVICE_ROLE_KEY");
  const evidencePath = required(environment, "EVIDENCE_PATH");
  const mode = modeFromEnvironment(environment);
  const startBoundary = dependencies.startBoundary ?? databaseStartBoundary;
  const digest = fixtureDigest(target, recipient, fixtureSecret);
  const context = {
    admin: createClient(supabaseUrl, serviceRoleKey, {
      auth: {
        autoRefreshToken: false,
        detectSessionInUrl: false,
        persistSession: false,
      },
    }),
    databaseUrl,
    evidencePath,
    fixture: fixtureIdentity(digest),
    fixtureDigest: digest,
    fixtureSecret,
    recipient,
    startedAt: mode === "normal" ? await startBoundary(databaseUrl) : null,
    target,
  };
  context.recordState = async (challengeIds) => writePrivateJson(
    statePath(evidencePath),
    {
      challengeIds,
      fixtureDigest: context.fixtureDigest,
      grantId: context.fixture.grantId,
      memberId: context.fixture.memberId,
      relationNumber: context.fixture.relationNumber,
      staffUserId: context.fixture.staffUserId,
      startedAt: context.startedAt,
    },
  );
  const run = dependencies.run ?? defaultRun;
  const cleanup = dependencies.cleanup ?? defaultCleanup;
  const verifyCleanup = dependencies.verifyCleanup ?? defaultVerifyCleanup;

  if (mode === "normal") {
    // Create cleanup state before the first external mutation. The workflow's
    // always() cleanup can therefore also complete after an early probe error.
    await context.recordState([]);
    const result = await run(context, dependencies.helpers);
    const evidence = validateEvidence(result.evidence, target);
    if (evidence.fixtureDigest !== context.fixtureDigest || evidence.cleanupComplete) {
      throw new Error("STAGING_EVIDENCE_VALUE_INVALID");
    }
    await writePrivateJson(evidencePath, evidence);
    await writePrivateJson(statePath(evidencePath), result.state);
    return evidence;
  }

  const state = await readJson(statePath(evidencePath), "STAGING_CLEANUP_STATE_MISSING");
  if (mode === "cleanup") {
    await cleanup(context, state);
    return null;
  }

  const evidence = validateEvidence(await readJson(evidencePath, "STAGING_EVIDENCE_MISSING"), target);
  if (evidence.fixtureDigest !== context.fixtureDigest) throw new Error("STAGING_EVIDENCE_VALUE_INVALID");
  await verifyCleanup(context, state);
  const complete = validateEvidence({ ...evidence, cleanupComplete: true }, target, { requireCleanup: true });
  await writePrivateJson(evidencePath, complete);
  await unlink(statePath(evidencePath)).catch(() => {});
  return complete;
}

async function main() {
  try {
    await runAcceptance();
    process.stdout.write("Parent-login stagingacceptatie geslaagd.\n");
  } catch (error) {
    process.stderr.write(`${stableFailureCode(error)}\n`);
    process.exitCode = 1;
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) await main();
