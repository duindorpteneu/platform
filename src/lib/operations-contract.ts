import { z } from "zod";

export const operationalHealthSchema = z.object({
  emailJobs: z.object({
    queued: z.number().int().nonnegative(),
    retry: z.number().int().nonnegative(),
    processingStale: z.number().int().nonnegative(),
    deliveryUncertain: z.number().int().nonnegative(),
    failed: z.number().int().nonnegative(),
    oldestPendingAt: z.string().datetime({ offset: true }).nullable(),
  }).strict(),
  operations: z.object({
    emailWorker: z.object({
      required: z.boolean(),
      lastStatus: z.enum(["running", "succeeded", "failed", "paused"]).nullable(),
      lastStartedAt: z.string().datetime({ offset: true }).nullable(),
      lastSucceededAt: z.string().datetime({ offset: true }).nullable(),
      stale: z.boolean(),
      runningStale: z.boolean(),
    }).strict(),
    importWorker: z.object({
      required: z.boolean(),
      lastStatus: z.enum(["running", "succeeded", "failed", "paused"]).nullable(),
      lastStartedAt: z.string().datetime({ offset: true }).nullable(),
      lastSucceededAt: z.string().datetime({ offset: true }).nullable(),
      stale: z.boolean(),
      runningStale: z.boolean(),
    }).strict(),
    retention: z.object({
      required: z.literal(true),
      lastStatus: z.enum(["running", "succeeded", "failed", "paused"]).nullable(),
      lastStartedAt: z.string().datetime({ offset: true }).nullable(),
      lastSucceededAt: z.string().datetime({ offset: true }).nullable(),
      stale: z.boolean(),
      runningStale: z.boolean(),
    }).strict(),
  }).strict(),
  importControl: z.object({
    processingEnabled: z.boolean(),
    cutoverActive: z.boolean(),
  }).strict(),
  importStaging: z.object({
    pending: z.number().int().nonnegative(),
    expired: z.number().int().nonnegative(),
    oldestExpiresAt: z.string().datetime({ offset: true }).nullable(),
  }).strict(),
  importRuns: z.object({
    queued: z.number().int().nonnegative(),
    processing: z.number().int().nonnegative(),
    processingStale: z.number().int().nonnegative(),
    failed: z.number().int().nonnegative(),
    reconciliationRequired: z.number().int().nonnegative(),
    expiredSelectedRows: z.number().int().nonnegative(),
    backlogStale: z.boolean(),
    oldestPendingAt: z.string().datetime({ offset: true }).nullable(),
  }).strict(),
  recentDeliveryFailures: z.number().int().nonnegative(),
  reconciliationIssues: z.number().int().nonnegative(),
  recentWebhookFailures: z.number().int().nonnegative(),
  dbTime: z.string().datetime({ offset: true }),
}).strict();

export function operationalHealthIsDegraded(
  data: z.infer<typeof operationalHealthSchema>,
) {
  return data.emailJobs.processingStale > 0
    || data.emailJobs.deliveryUncertain > 0
    || data.emailJobs.failed > 0
    || data.recentDeliveryFailures > 0
    || data.reconciliationIssues > 0
    || data.recentWebhookFailures > 0
    || data.operations.emailWorker.stale
    || data.operations.emailWorker.runningStale
    || data.operations.emailWorker.lastStatus === "failed"
    || data.operations.importWorker.stale
    || data.operations.importWorker.runningStale
    || data.operations.importWorker.lastStatus === "failed"
    || data.operations.retention.stale
    || data.operations.retention.runningStale
    || data.operations.retention.lastStatus === "failed"
    || (
      data.importControl.processingEnabled
      && !data.importControl.cutoverActive
    )
    || data.importStaging.expired > 0
    || data.importRuns.processingStale > 0
    || data.importRuns.failed > 0
    || data.importRuns.reconciliationRequired > 0
    || data.importRuns.expiredSelectedRows > 0
    || data.importRuns.backlogStale;
}

export const operationStartResponseSchema = z.object({
  runId: z.string().uuid(),
  operation: z.enum(["email_worker", "import_worker", "inventory_allocator", "retention"]),
  startedAt: z.string().datetime({ offset: true }),
}).strict();

export const operationFinishResponseSchema = z.object({
  runId: z.string().uuid(),
  operation: z.enum(["email_worker", "import_worker", "inventory_allocator", "retention"]),
  status: z.enum(["succeeded", "failed", "paused"]),
  finishedAt: z.string().datetime({ offset: true }),
}).strict();

export const retentionResultSchema = z.object({
  otpChallenges: z.number().int().nonnegative(),
  rateLimitEvents: z.number().int().nonnegative(),
  parentSessions: z.number().int().nonnegative(),
  emailEvents: z.number().int().nonnegative(),
  importStaging: z.number().int().nonnegative(),
  importSelectedRows: z.number().int().nonnegative(),
  importRunsExpired: z.number().int().nonnegative(),
  importPartialFailures: z.number().int().nonnegative(),
  importPlansPurged: z.number().int().nonnegative(),
}).strict();
