import { z } from "zod";

const uuidSchema = z.string().uuid();
const revisionSchema = z.string().regex(/^[0-9a-f]{64}$/);

export const deliveryNotificationClassificationSchema = z.enum([
  "eligible",
  "skipped",
  "blocked",
]);

export const deliveryNotificationItemSchema = z.object({
  id: uuidSchema,
  allocationEventId: uuidSchema,
  allocationId: uuidSchema,
  productName: z.string().min(1).max(120),
  size: z.string().min(1).max(80),
  quantity: z.number().int().positive().max(25),
  classification: deliveryNotificationClassificationSchema,
  reasonCode: z.string().min(3).max(80),
  eventCount: z.number().int().nonnegative(),
  selectedByDefault: z.boolean(),
}).strict();

export const deliveryNotificationProposalSchema = z.object({
  id: uuidSchema,
  deliveryDraftId: uuidSchema,
  seasonId: uuidSchema,
  receiptId: uuidSchema,
  status: z.enum(["open", "confirmed"]),
  eligibilityRevision: revisionSchema,
  selectedCount: z.number().int().nonnegative(),
  eligibleCount: z.number().int().nonnegative(),
  skippedCount: z.number().int().nonnegative(),
  blockedCount: z.number().int().nonnegative(),
  eventCount: z.number().int().nonnegative(),
  parentGroupCount: z.number().int().nonnegative(),
  createdAt: z.string().datetime({ offset: true }),
  confirmedAt: z.string().datetime({ offset: true }).nullable(),
  items: z.array(deliveryNotificationItemSchema),
}).strict();

export const deliveryNotificationConfirmRequestSchema = z.object({
  proposalId: uuidSchema,
  expectedRevision: revisionSchema,
  excludedItemIds: z.array(uuidSchema).max(500),
  requestId: uuidSchema,
}).strict().superRefine((value, context) => {
  if (new Set(value.excludedItemIds).size !== value.excludedItemIds.length) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      path: ["excludedItemIds"],
      message: "Een notificatieregel mag maar één keer worden geselecteerd.",
    });
  }
});

export const deliveryNotificationConfirmResponseSchema = z.object({
  proposalId: uuidSchema,
  status: z.literal("confirmed"),
  selectedCount: z.number().int().nonnegative(),
  eligibleCount: z.number().int().nonnegative(),
  skippedCount: z.number().int().nonnegative(),
  blockedCount: z.number().int().nonnegative(),
  eventCount: z.number().int().nonnegative(),
  parentGroupCount: z.number().int().nonnegative(),
  reused: z.boolean(),
}).strict();

export type DeliveryNotificationProposal = z.infer<
  typeof deliveryNotificationProposalSchema
>;
export type DeliveryNotificationConfirmRequest = z.infer<
  typeof deliveryNotificationConfirmRequestSchema
>;
