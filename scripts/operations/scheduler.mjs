import { writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const STAGING_BASE = "http://app:3000";
const ALLOWED_ENVIRONMENTS = new Set(["staging", "production"]);
const HEALTH_DIAGNOSTIC_PATHS = [
  "status",
  "error",
  "importGateMatches",
  "emailJobs.processingStale",
  "emailJobs.deliveryUncertain",
  "emailJobs.failed",
  "emailDeliveryAttempts.legacyAmbiguous",
  "emailDeliveryAttempts.quarantinedEvents",
  "emailDeliveryAttempts.unboundLegacyEvents",
  "emailDeliveryAttempts.processingWithoutCurrentAttempt",
  "reminderPlanner.failedRunsRecent",
  "reminderPlanner.activeRulesNeverRun",
  "parentOtpDelivery.stalePrepared",
  "parentOtpDelivery.deliveryUncertainRecent",
  "parentOtpDelivery.sendFailuresRecent",
  "parentOtpDelivery.quarantinedEvents",
  "parentOtpDelivery.providerFailuresRecent",
  "supplierPlanning.activePrincipalsWithoutOpenSeason",
  "supplierPlanning.unauthorizedActiveSessions",
  "supplierPlanning.expiredUnrevokedSessions",
  "supplierPlanning.recentLoginFailures",
  "supplierPlanning.staleCredentials",
  "recentDeliveryFailures",
  "reconciliationIssues",
  "recentWebhookFailures",
  "brandingProjection.blockers",
  "operations.emailWorker.stale",
  "operations.emailWorker.runningStale",
  "operations.emailWorker.lastStatus",
  "operations.importWorker.stale",
  "operations.importWorker.runningStale",
  "operations.importWorker.lastStatus",
  "operations.inventoryAllocator.stale",
  "operations.inventoryAllocator.runningStale",
  "operations.inventoryAllocator.lastStatus",
  "inventoryAllocationQueue.runnable",
  "inventoryAllocationQueue.processing",
  "inventoryAllocationQueue.terminalExhausted",
  "inventoryAllocationQueue.poisoned",
  "inventoryAllocationQueue.oldestRunnableAt",
  "operations.retention.stale",
  "operations.retention.runningStale",
  "operations.retention.lastStatus",
  "importControl.processingEnabled",
  "importControl.cutoverActive",
  "importStaging.expired",
  "importRuns.processingStale",
  "importRuns.failed",
  "importRuns.reconciliationRequired",
  "importRuns.expiredSelectedRows",
  "importRuns.backlogStale",
  "qrControl.cutoverActive",
  "qrControl.scannerActive",
  "qrControl.candidateOrders",
  "qrControl.activeLegacyQr",
  "qrControl.expiredOpenGrants",
  "qrControl.keyMismatchActiveLocators",
  "qrControl.keyMismatchOpenGrants",
  "emailControl.gateMatches",
  "emailControl.providerConfigured",
  "emailControl.keyFingerprintMatches",
  "emailControl.testEventQuarantined",
];

export function operationalHealthDiagnostic(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return { response: "invalid" };
  }
  const diagnostic = {};
  for (const path of HEALTH_DIAGNOSTIC_PATHS) {
    let value = body;
    for (const segment of path.split(".")) {
      if (!value || typeof value !== "object" || Array.isArray(value)) {
        value = undefined;
        break;
      }
      value = value[segment];
    }
    if (value === null || ["boolean", "number", "string"].includes(typeof value)) {
      diagnostic[path] = value;
    }
  }
  return diagnostic;
}

export function validateSchedulerConfig(environment = process.env) {
  const appEnvironment = environment.APP_ENVIRONMENT?.trim() ?? "";
  const cronSecret = environment.CRON_SECRET?.trim() ?? "";
  const internalBaseUrl = environment.OPERATIONS_INTERNAL_BASE_URL?.trim() || STAGING_BASE;
  const heartbeatUrl = environment.OPERATIONS_HEARTBEAT_URL?.trim() ?? "";
  const emailEnabled = environment.EMAIL_ENABLED === "true";
  const dynamicImportEnabled = environment.DYNAMIC_IMPORT_ENABLED === "true";

  if (!ALLOWED_ENVIRONMENTS.has(appEnvironment)) throw new Error("SCHEDULER_ENVIRONMENT_INVALID");
  if (cronSecret.length < 16 || /[\r\n\0]/.test(cronSecret)) throw new Error("SCHEDULER_SECRET_INVALID");
  if (internalBaseUrl !== STAGING_BASE) throw new Error("SCHEDULER_INTERNAL_TARGET_INVALID");
  if (appEnvironment === "production" && !heartbeatUrl) throw new Error("SCHEDULER_HEARTBEAT_REQUIRED");
  if (heartbeatUrl) {
    const parsed = new URL(heartbeatUrl);
    if (parsed.protocol !== "https:" || parsed.username || parsed.password) throw new Error("SCHEDULER_HEARTBEAT_INVALID");
  }

  return {
    appEnvironment,
    cronSecret,
    internalBaseUrl,
    heartbeatUrl,
    emailEnabled,
    dynamicImportEnabled,
  };
}

export function shouldRunRetention(now, lastRetentionAt) {
  const previous = lastRetentionAt ? new Date(lastRetentionAt) : null;
  const validPrevious = previous && Number.isFinite(previous.getTime());
  return {
    timestamp: now.toISOString(),
    due: !validPrevious || now.getTime() - previous.getTime() >= 5 * 60 * 1_000,
  };
}

async function fetchJson(url, init, timeoutMs = 55_000) {
  const response = await fetch(url, { ...init, redirect: "error", signal: AbortSignal.timeout(timeoutMs) });
  const body = await response.json().catch(() => null);
  if (!response.ok || !body || typeof body !== "object") {
    if (url.endsWith("/api/internal/health")) {
      console.error(JSON.stringify({
        event: "scheduler_health_degraded",
        httpStatus: response.status,
        fields: operationalHealthDiagnostic(body),
      }));
    }
    throw new Error(`HTTP_${response.status}`);
  }
  return body;
}

function internalRouteCode(path) {
  if (path.endsWith("/email")) return "EMAIL_JOB";
  if (path.endsWith("/imports")) return "IMPORT_JOB";
  if (path.endsWith("/inventory")) return "INVENTORY_JOB";
  if (path.endsWith("/retention")) return "RETENTION_JOB";
  if (path.endsWith("/health")) return "INTERNAL_HEALTH";
  return "INTERNAL_JOB";
}

export async function invokeInternal(config, path, method, fetcher = fetchJson) {
  let body;
  try {
    body = await fetcher(`${config.internalBaseUrl}${path}`, {
      method,
      headers: { authorization: `Bearer ${config.cronSecret}`, accept: "application/json" },
    });
  } catch (error) {
    const detail = error instanceof Error && /^[A-Z0-9_]+$/.test(error.message)
      ? error.message
      : "REQUEST_FAILED";
    throw new Error(`${internalRouteCode(path)}_${detail}`);
  }
  if (path.endsWith("/email")) {
    if (!new Set(["processed", "paused"]).has(body.status)) throw new Error("EMAIL_RESPONSE_INVALID");
    if (config.emailEnabled && body.status === "paused") throw new Error("EMAIL_UNEXPECTEDLY_PAUSED");
  } else if (path.endsWith("/imports")) {
    if (!new Set(["idle", "processing", "previewed", "committed", "paused"]).has(body.status)) {
      throw new Error("IMPORT_RESPONSE_INVALID");
    }
    if (config.dynamicImportEnabled && body.status === "paused") {
      throw new Error("IMPORT_UNEXPECTEDLY_PAUSED");
    }
  } else if (path.endsWith("/inventory")) {
    if (!new Set(["succeeded", "paused"]).has(body.status)) {
      throw new Error("INVENTORY_RESPONSE_INVALID");
    }
  } else if (path.endsWith("/retention")) {
    if (body.status !== "completed") throw new Error("RETENTION_RESPONSE_INVALID");
  } else if (path.endsWith("/health")) {
    if (body.status !== "healthy") throw new Error("OPERATIONS_DEGRADED");
  }
  return body;
}

async function pingHeartbeat(config) {
  if (!config.heartbeatUrl) return;
  const response = await fetch(config.heartbeatUrl, {
    method: "GET",
    redirect: "error",
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new Error(`HEARTBEAT_HTTP_${response.status}`);
}

export async function runSchedulerCycle(
  config,
  state,
  now = new Date(),
  dependencies = {},
) {
  const invoke = dependencies.invoke ?? invokeInternal;
  const heartbeat = dependencies.heartbeat ?? pingHeartbeat;
  const healthWriter = dependencies.healthWriter
    ?? ((timestamp) => writeFile("/tmp/scheduler-health", timestamp, { mode: 0o600 }));
  let firstFailure;
  try {
    await invoke(config, "/api/internal/jobs/email", "POST");
  } catch (error) {
    firstFailure = error;
  }
  try {
    await invoke(config, "/api/internal/jobs/imports", "POST");
  } catch (error) {
    firstFailure ??= error;
  }
  try {
    await invoke(config, "/api/internal/jobs/inventory", "POST");
  } catch (error) {
    firstFailure ??= error;
  }
  const retention = shouldRunRetention(now, state.lastRetentionAt);
  if (retention.due) {
    try {
      await invoke(config, "/api/internal/jobs/retention", "POST");
      state.lastRetentionAt = retention.timestamp;
    } catch (error) {
      firstFailure ??= error;
    }
  }
  try {
    await invoke(config, "/api/internal/health", "GET");
  } catch (error) {
    firstFailure ??= error;
  }
  // The heartbeat is an independent liveness signal. A degraded application
  // health response must remain visible, but must not make a running scheduler
  // look dead to the external monitor.
  try {
    await heartbeat(config);
  } catch (error) {
    firstFailure ??= error;
  }
  if (firstFailure) throw firstFailure;
  await healthWriter(now.toISOString());
  return state;
}

async function main() {
  const config = validateSchedulerConfig();
  const state = { lastRetentionAt: "" };
  let failures = 0;
  console.log(JSON.stringify({ event: "scheduler_started", environment: config.appEnvironment }));
  for (;;) {
    const startedAt = new Date();
    try {
      await runSchedulerCycle(config, state, startedAt);
      if (failures > 0) console.log(JSON.stringify({ event: "scheduler_recovered", failures }));
      failures = 0;
    } catch (error) {
      failures += 1;
      const code = error instanceof Error && /^[A-Z0-9_]+$/.test(error.message) ? error.message : "SCHEDULER_CYCLE_FAILED";
      console.error(JSON.stringify({ event: "scheduler_cycle_failed", code, failures }));
    }
    const elapsed = Date.now() - startedAt.getTime();
    const waitMs = Math.max(1_000, 60_000 - (elapsed % 60_000));
    await new Promise((resolve) => setTimeout(resolve, waitMs));
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  main().catch(() => {
    console.error(JSON.stringify({ event: "scheduler_fatal", code: "SCHEDULER_START_FAILED" }));
    process.exit(1);
  });
}
