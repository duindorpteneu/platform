import { z } from "zod";

export const EXPORT_TYPES = [
  "members",
  "orders",
  "package_orders",
  "package_items",
  "payments",
  "deliveries",
  "fulfilments",
  "outstanding",
] as const;
export const exportTypeSchema = z.enum(EXPORT_TYPES);
export const exportFormatSchema = z.enum(["csv", "xlsx"]);

const primitiveSchema = z.union([z.string(), z.number().finite(), z.boolean(), z.null()]);
const exportColumnSchema = z.object({
  key: z.string().regex(/^[a-z][a-zA-Z0-9_]*$/),
  label: z.string().trim().min(1).max(100),
}).strict();

export const exportPayloadSchema = z.object({
  type: exportTypeSchema,
  seasonName: z.string().trim().min(1).max(100),
  generatedAt: z.string().datetime({ offset: true }),
  columns: z.array(exportColumnSchema).min(1).max(40),
  rows: z.array(z.record(z.string(), primitiveSchema)).max(50_000),
}).strict();

const filterOptionSchema = z.object({ value: z.string().max(100), label: z.string().trim().min(1).max(100) }).strict();
const filterMapSchema = z.object({
  members: z.array(filterOptionSchema).max(100),
  orders: z.array(filterOptionSchema).max(100),
  package_orders: z.array(filterOptionSchema).max(100),
  package_items: z.array(filterOptionSchema).max(100),
  payments: z.array(filterOptionSchema).max(100),
  deliveries: z.array(filterOptionSchema).max(100),
  fulfilments: z.array(filterOptionSchema).max(100),
  outstanding: z.array(filterOptionSchema).max(100),
}).strict();

export const exportWorkspaceSchema = z.object({
  types: z.tuple([
    z.literal("members"),
    z.literal("orders"),
    z.literal("package_orders"),
    z.literal("package_items"),
    z.literal("payments"),
    z.literal("deliveries"),
    z.literal("fulfilments"),
    z.literal("outstanding"),
  ]),
  seasons: z.array(z.object({ id: z.string().uuid(), name: z.string().trim().min(1).max(100), active: z.boolean() }).strict()).max(50),
  filters: filterMapSchema,
}).strict();

export type ExportType = z.infer<typeof exportTypeSchema>;
export type ExportPayload = z.infer<typeof exportPayloadSchema>;
export type ExportWorkspace = z.infer<typeof exportWorkspaceSchema>;
