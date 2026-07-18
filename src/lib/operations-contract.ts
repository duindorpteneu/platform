import { z } from "zod";

export const operationalHealthSchema = z.object({
  emailJobs: z.object({ queued: z.number().int().nonnegative(), retry: z.number().int().nonnegative(), processingStale: z.number().int().nonnegative(), failed: z.number().int().nonnegative() }).strict(),
  reconciliationIssues: z.number().int().nonnegative(),
  recentWebhookFailures: z.number().int().nonnegative(),
  dbTime: z.string().datetime({ offset: true }),
}).strict();

export const retentionResultSchema = z.object({
  otpChallenges: z.number().int().nonnegative(),
  rateLimitEvents: z.number().int().nonnegative(),
  parentSessions: z.number().int().nonnegative(),
  emailEvents: z.number().int().nonnegative(),
}).strict();

