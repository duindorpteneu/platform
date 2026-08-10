import { z } from "zod";

const uuidSchema = z.string().uuid();
const isoDateSchema = z.string().regex(/^\d{4}-\d{2}-\d{2}$/).refine(
  (value) => {
    const parsed = new Date(`${value}T00:00:00.000Z`);
    return !Number.isNaN(parsed.valueOf()) && parsed.toISOString().slice(0, 10) === value;
  },
  "Ongeldige datum.",
);

export const deliveryReceiptRequestSchema = z.object({
  receivedOn: isoDateSchema,
  supplier: z.string().trim().min(1).max(160),
  packingSlipReference: z.string().trim().min(1).max(160).optional(),
  lines: z.array(z.object({
    variantId: uuidSchema,
    quantity: z.number().int().positive().max(10_000),
  }).strict()).min(1).max(250),
}).strict().superRefine((value, context) => {
  const variantIds = value.lines.map((line) => line.variantId);
  if (new Set(variantIds).size !== variantIds.length) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "Een artikelvariant mag maar één keer voorkomen.", path: ["lines"] });
  }
});

export const stockReservationRequestSchema = z.object({
  receiptLineId: uuidSchema,
  orderLineIds: z.array(uuidSchema).min(1).max(500),
}).strict().superRefine((value, context) => {
  if (new Set(value.orderLineIds).size !== value.orderLineIds.length) {
    context.addIssue({ code: z.ZodIssueCode.custom, message: "Een orderregel mag maar één keer voorkomen.", path: ["orderLineIds"] });
  }
});

const requestIdSchema = uuidSchema;

export const inventoryWorkspaceQuerySchema = z.object({
  seasonId: uuidSchema.optional(),
}).strict();

export const inventoryDraftCreateSchema = z.object({
  seasonId: uuidSchema,
  receivedOn: isoDateSchema,
  supplier: z.string().trim().min(1).max(160),
  packingSlipReference: z.string().trim().min(1).max(160).optional(),
  articleIds: z.array(uuidSchema).min(1).max(50),
  requestId: requestIdSchema,
}).strict().superRefine((value, context) => {
  if (new Set(value.articleIds).size !== value.articleIds.length) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      message: "Een product mag maar één keer worden geselecteerd.",
      path: ["articleIds"],
    });
  }
});

export const inventoryDraftUpdateSchema = z.object({
  expectedRevision: z.number().int().positive(),
  requestId: requestIdSchema,
  lines: z.array(z.object({
    variantId: uuidSchema,
    quantity: z.number().int().min(0).max(10_000).nullable(),
    confirmed: z.boolean(),
  }).strict()).min(1).max(500),
}).strict().superRefine((value, context) => {
  if (new Set(value.lines.map((line) => line.variantId)).size !== value.lines.length) {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      message: "Een maatregel mag maar één keer voorkomen.",
      path: ["lines"],
    });
  }
  value.lines.forEach((line, index) => {
    if (line.confirmed && line.quantity === null) {
      context.addIssue({
        code: z.ZodIssueCode.custom,
        message: "Een bevestigde maatregel vereist een aantal of expliciete nul.",
        path: ["lines", index, "quantity"],
      });
    }
  });
});

export const inventoryDraftPostSchema = z.object({
  expectedRevision: z.number().int().positive(),
  requestId: requestIdSchema,
  correlationId: uuidSchema.optional(),
}).strict();

export const inventoryDraftCancelSchema = z.object({
  expectedRevision: z.number().int().positive(),
  reason: z.string().trim().min(4).max(500),
  requestId: requestIdSchema,
  correlationId: uuidSchema.optional(),
}).strict();

export const inventoryThresholdSchema = z.object({
  seasonId: uuidSchema,
  threshold: z.number().int().min(0).max(100_000),
  reason: z.string().trim().min(4).max(500),
  correlationId: uuidSchema.optional(),
}).strict();

export const inventoryLegacyAssignmentSchema = z.object({
  reconciliationId: uuidSchema,
  seasonId: uuidSchema,
  quantity: z.number().int().positive().max(100_000),
  reason: z.string().trim().min(4).max(500),
  requestId: requestIdSchema,
  correlationId: uuidSchema.optional(),
}).strict();

export const inventoryLegacyAllocationResolutionSchema = z.object({
  allocationId: uuidSchema,
  decision: z.enum(["release_requeue", "accept_historical"]),
  reason: z.string().trim().min(4).max(500),
  requestId: requestIdSchema,
  correlationId: uuidSchema.optional(),
}).strict();
