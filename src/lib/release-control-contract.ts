import { z } from "zod";

const revision = z.string().regex(/^[a-f0-9]{64}$/);
const baseControl = z.object({
  enabled: z.boolean(),
  ready: z.boolean(),
  blockerCount: z.number().int().nonnegative(),
});

export const releaseFeatureControlsSchema = z.object({
  revision,
  flags: z.array(z.object({
    key: z.string(),
    enabled: z.boolean(),
    description: z.string(),
    updatedAt: z.string(),
  })),
  memberSeasons: baseControl,
  packageOrders: baseControl.extend({
    dependencyReady: z.boolean(),
  }),
  dynamicImport: baseControl.extend({
    cutoverActive: z.boolean(),
  }),
});

export const parentAccessCutoverSchema = z.object({
  enabled: z.boolean(),
  ready: z.boolean(),
  unresolvedGrantCount: z.number().int().nonnegative(),
  unresolvedLegacyLinkCount: z.number().int().nonnegative(),
  revision,
});

export const allocationQrCutoverSchema = z.object({
  enabled: z.boolean(),
  ready: z.boolean(),
  revision,
  brandingProjectionBlockers: z.number().int().nonnegative().default(0),
}).passthrough();

export const releaseControlWorkspaceSchema = z.object({
  base: releaseFeatureControlsSchema,
  parentAccess: parentAccessCutoverSchema,
  allocationQr: allocationQrCutoverSchema,
});

export const manageReleaseControlRequestSchema = z.object({
  action: z.enum(["activate", "pause"]),
  key: z.enum([
    "member_seasons_v2",
    "package_orders_v2",
    "dynamic_import_v2",
    "parent_access_grants_v2",
    "allocation_qr_v2",
  ]),
  expectedRevision: revision,
  reason: z.string().trim().min(4).max(500),
}).strict().superRefine((value, context) => {
  if (value.action === "pause" && value.key !== "dynamic_import_v2") {
    context.addIssue({
      code: z.ZodIssueCode.custom,
      message: "Alleen dynamische import ondersteunt een operationele pauze.",
      path: ["action"],
    });
  }
});

export type ReleaseControlWorkspace = z.infer<
  typeof releaseControlWorkspaceSchema
>;
export type ManageReleaseControlRequest = z.infer<
  typeof manageReleaseControlRequestSchema
>;
