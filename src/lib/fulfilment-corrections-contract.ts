import { z } from "zod";
import { memberLineStatusSchema } from "@/lib/member-overview-contract";

export const fulfilmentCorrectionsWorkspaceSchema = z.object({
  fulfilments: z.array(z.object({
    id: z.string().uuid(), orderId: z.string().uuid(),
    memberName: z.string().min(1).max(320), relationNumber: z.string().min(1).max(120).nullable(),
    team: z.string().min(1).max(120), location: z.string().min(1).max(160),
    fulfilledAt: z.string().datetime({ offset: true }), correctedAt: z.string().datetime({ offset: true }).nullable(),
    lines: z.array(z.object({
      id: z.string().uuid(), orderLineId: z.string().uuid(), article: z.string().min(1).max(120),
      size: z.string().min(1).max(80), quantity: z.number().int().positive(), status: memberLineStatusSchema,
      reversedAt: z.string().datetime({ offset: true }).nullable(), reversalReason: z.string().min(1).max(500).nullable(),
    }).strict()).max(100),
  }).strict()).max(100),
}).strict();

export type FulfilmentCorrectionsWorkspace = z.infer<typeof fulfilmentCorrectionsWorkspaceSchema>;
