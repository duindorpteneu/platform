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
