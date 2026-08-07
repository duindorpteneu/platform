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
  emailDeliveryAttempts: z.object({
    legacyAmbiguous: z.number().int().nonnegative(),
    quarantinedEvents: z.number().int().nonnegative(),
    unboundLegacyEvents: z.number().int().nonnegative(),
    processingWithoutCurrentAttempt: z.number().int().nonnegative(),
  }).strict().default({
    legacyAmbiguous: 0,
    quarantinedEvents: 0,
    unboundLegacyEvents: 0,
    processingWithoutCurrentAttempt: 0,
  }),
  reminderPlanner: z.object({
    activeRules: z.number().int().nonnegative(),
    failedRunsRecent: z.number().int().nonnegative(),
    activeRulesNeverRun: z.number().int().nonnegative(),
    lastCompletedAt: z.string().datetime({ offset: true }).nullable(),
  }).strict().default({
    activeRules: 0,
    failedRunsRecent: 0,
    activeRulesNeverRun: 0,
    lastCompletedAt: null,
  }),
  parentOtpDelivery: z.object({
    stalePrepared: z.number().int().nonnegative(),
    deliveryUncertainRecent: z.number().int().nonnegative(),
    sendFailuresRecent: z.number().int().nonnegative(),
    quarantinedEvents: z.number().int().nonnegative(),
    providerFailuresRecent: z.number().int().nonnegative(),
  }).strict().default({
    stalePrepared: 0,
    deliveryUncertainRecent: 0,
    sendFailuresRecent: 0,
    quarantinedEvents: 0,
    providerFailuresRecent: 0,
  }),
  supplierPlanning: z.object({
    activePrincipals: z.number().int().nonnegative(),
    activePrincipalsWithoutOpenSeason: z.number().int().nonnegative(),
    activeSessions: z.number().int().nonnegative(),
    unauthorizedActiveSessions: z.number().int().nonnegative(),
    expiredUnrevokedSessions: z.number().int().nonnegative(),
    recentLoginFailures: z.number().int().nonnegative(),
    staleCredentials: z.number().int().nonnegative(),
    lastSuccessfulPlanningAt: z.string().datetime({ offset: true }).nullable(),
  }).strict().default({
    activePrincipals: 0,
    activePrincipalsWithoutOpenSeason: 0,
    activeSessions: 0,
    unauthorizedActiveSessions: 0,
    expiredUnrevokedSessions: 0,
    recentLoginFailures: 0,
    staleCredentials: 0,
    lastSuccessfulPlanningAt: null,
  }),
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
    inventoryAllocator: z.object({
      required: z.literal(true),
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
  qrControl: z.object({
    cutoverActive: z.boolean(),
    scannerActive: z.boolean(),
    candidateOrders: z.number().int().nonnegative(),
    activeLegacyQr: z.number().int().nonnegative(),
    openGrants: z.number().int().nonnegative(),
    expiredOpenGrants: z.number().int().nonnegative(),
    keyMismatchActiveLocators: z.number().int().nonnegative(),
    keyMismatchOpenGrants: z.number().int().nonnegative(),
    previousKeyActiveLocators: z.number().int().nonnegative(),
    previousKeyOpenGrants: z.number().int().nonnegative(),
  }).strict(),
  importControl: z.object({
    processingEnabled: z.boolean(),
    cutoverActive: z.boolean(),
  }).strict(),
  emailControl: z.object({
    processingEnabled: z.boolean(),
    testEventQuarantined: z.number().int().nonnegative(),
  }).strict(),
  brandingProjection: z.object({
    blockers: z.number().int().nonnegative(),
  }).strict().default({ blockers: 0 }),
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

export function emailDeliveryAttemptHealthHasIntegrityBlocker(
  data: z.infer<typeof operationalHealthSchema>,
) {
  return data.emailDeliveryAttempts.legacyAmbiguous > 0
    || data.emailDeliveryAttempts.quarantinedEvents > 0
    || data.emailDeliveryAttempts.unboundLegacyEvents > 0
    || data.emailDeliveryAttempts.processingWithoutCurrentAttempt > 0;
}

export function operationalHealthIsDegraded(
  data: z.infer<typeof operationalHealthSchema>,
) {
  return data.emailJobs.processingStale > 0
    || data.emailJobs.deliveryUncertain > 0
    || data.emailJobs.failed > 0
    || emailDeliveryAttemptHealthHasIntegrityBlocker(data)
    || data.reminderPlanner.failedRunsRecent > 0
    || data.reminderPlanner.activeRulesNeverRun > 0
    || data.parentOtpDelivery.stalePrepared > 0
    || data.parentOtpDelivery.deliveryUncertainRecent > 0
    || data.parentOtpDelivery.sendFailuresRecent > 0
    || data.parentOtpDelivery.quarantinedEvents > 0
    || data.parentOtpDelivery.providerFailuresRecent > 0
    || data.supplierPlanning.activePrincipalsWithoutOpenSeason > 0
    || data.supplierPlanning.unauthorizedActiveSessions > 0
    || data.supplierPlanning.expiredUnrevokedSessions > 0
    || data.supplierPlanning.recentLoginFailures >= 50
    || data.supplierPlanning.staleCredentials > 0
    || data.recentDeliveryFailures > 0
    || data.reconciliationIssues > 0
    || data.recentWebhookFailures > 0
    || data.brandingProjection.blockers > 0
    || data.operations.emailWorker.stale
    || data.operations.emailWorker.runningStale
    || data.operations.emailWorker.lastStatus === "failed"
    || data.operations.importWorker.stale
    || data.operations.importWorker.runningStale
    || data.operations.importWorker.lastStatus === "failed"
    || data.operations.inventoryAllocator.stale
    || data.operations.inventoryAllocator.runningStale
    || data.operations.inventoryAllocator.lastStatus === "failed"
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
    || data.importRuns.backlogStale
    || data.qrControl.expiredOpenGrants > 0
    || data.qrControl.keyMismatchActiveLocators > 0
    || data.qrControl.keyMismatchOpenGrants > 0
    || (
      data.qrControl.cutoverActive
      && (
        !data.qrControl.scannerActive
        || data.qrControl.candidateOrders > 0
        || data.qrControl.activeLegacyQr > 0
      )
    );
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
  campaignPreflights: z.number().int().nonnegative(),
  otpDeliveryHistory: z.number().int().nonnegative(),
  supplierPlanningHistory: z.number().int().nonnegative(),
}).strict();
