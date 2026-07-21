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
    retention: z.object({
      required: z.literal(true),
      lastStatus: z.enum(["running", "succeeded", "failed", "paused"]).nullable(),
      lastStartedAt: z.string().datetime({ offset: true }).nullable(),
      lastSucceededAt: z.string().datetime({ offset: true }).nullable(),
      stale: z.boolean(),
      runningStale: z.boolean(),
    }).strict(),
  }).strict(),
  recentDeliveryFailures: z.number().int().nonnegative(),
  reconciliationIssues: z.number().int().nonnegative(),
  recentWebhookFailures: z.number().int().nonnegative(),
  dbTime: z.string().datetime({ offset: true }),
}).strict();

export const operationStartResponseSchema = z.object({
  runId: z.string().uuid(),
  operation: z.enum(["email_worker", "retention"]),
  startedAt: z.string().datetime({ offset: true }),
}).strict();

export const operationFinishResponseSchema = z.object({
  runId: z.string().uuid(),
  operation: z.enum(["email_worker", "retention"]),
  status: z.enum(["succeeded", "failed", "paused"]),
  finishedAt: z.string().datetime({ offset: true }),
}).strict();

export const retentionResultSchema = z.object({
  otpChallenges: z.number().int().nonnegative(),
  rateLimitEvents: z.number().int().nonnegative(),
  parentSessions: z.number().int().nonnegative(),
  emailEvents: z.number().int().nonnegative(),
}).strict();
