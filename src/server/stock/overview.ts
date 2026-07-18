import { z } from "zod";

export const stockOverviewQuerySchema = z.object({
  variantId: z.string().uuid().optional(),
}).strict();
