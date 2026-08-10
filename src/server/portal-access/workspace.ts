import { unstable_noStore as noStore } from "next/cache";
import {
  portalAccessCommitResponseSchema,
  portalAccessPreviewDatabaseSchema,
  portalAccessWorkspaceSchema,
  type PortalAccessPreflightRequest,
} from "@/lib/portal-access-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { operationalLogger } from "@/server/security/logger";
import { getSupabaseServerClient } from "@/server/supabase/server";

export type PortalAccessRpcError = {
  code?: string;
  message?: string;
};

async function portalAccessClient() {
  const staff = await requireStaffRole(["beheerder"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("PORTAL_ACCESS_DATABASE_UNAVAILABLE");
  return { staff, supabase };
}

function logFailure(action: string, code: string) {
  operationalLogger.error(`portal_access.${action}_failed`, {
    code: code.toLowerCase(),
    provider: "supabase",
    route: "/backoffice/portaaltoegang",
  });
}

export async function getPortalAccessWorkspace(input: {
  seasonId: string | null;
  search: string | null;
  offset: number;
  limit: 50;
}) {
  noStore();
  const { staff, supabase } = await portalAccessClient();
  const { data, error } = await supabase.schema("app").rpc("get_parent_access_workspace", {
    p_season_id: input.seasonId,
    p_search: input.search,
    p_offset: input.offset,
    p_limit: input.limit,
  });
  if (error) {
    logFailure("workspace_load", error.code || "query_failed");
    return { data: null, staff, error: error as PortalAccessRpcError };
  }
  const parsed = portalAccessWorkspaceSchema.safeParse(data);
  if (!parsed.success) {
    logFailure("workspace_load", "response_invalid");
    throw new Error("PORTAL_ACCESS_WORKSPACE_RESPONSE_INVALID");
  }
  return { data: parsed.data, staff, error: null };
}

export async function previewPortalAccess(input: PortalAccessPreflightRequest) {
  const { staff, supabase } = await portalAccessClient();
  const call = input.operation === "activate"
    ? supabase.schema("app").rpc("preview_parent_portal_activation", {
      p_season_id: input.seasonId,
      p_member_season_ids: input.memberSeasonIds,
    })
    : supabase.schema("app").rpc("preview_parent_portal_revocation", {
      p_season_id: input.seasonId,
      p_grant_ids: input.grantIds,
    });
  const { data, error } = await call;
  if (error) {
    logFailure("preview", error.code || "query_failed");
    return { data: null, staff, error: error as PortalAccessRpcError };
  }
  const parsed = portalAccessPreviewDatabaseSchema.safeParse(data);
  if (!parsed.success || parsed.data.operation !== input.operation) {
    logFailure("preview", "response_invalid");
    throw new Error("PORTAL_ACCESS_PREVIEW_RESPONSE_INVALID");
  }
  return { data: parsed.data, staff, error: null };
}

export async function activatePortalAccess(input: {
  seasonId: string;
  memberSeasonIds: string[];
  expectedRevision: string;
  batchKey: string;
  correlationId: string | null;
}) {
  const { staff, supabase } = await portalAccessClient();
  const { data, error } = await supabase.schema("app").rpc("activate_parent_portal_access", {
    p_season_id: input.seasonId,
    p_member_season_ids: input.memberSeasonIds,
    p_expected_revision: input.expectedRevision,
    p_batch_key: input.batchKey,
    p_correlation_id: input.correlationId,
  });
  if (error) {
    logFailure("activate", error.code || "mutation_failed");
    return { data: null, staff, error: error as PortalAccessRpcError };
  }
  const parsed = portalAccessCommitResponseSchema.safeParse(data);
  if (!parsed.success || parsed.data.operation !== "activate") {
    logFailure("activate", "response_invalid");
    throw new Error("PORTAL_ACCESS_COMMIT_RESPONSE_INVALID");
  }
  return { data: parsed.data, staff, error: null };
}

export async function revokePortalAccess(input: {
  seasonId: string;
  grantIds: string[];
  reason: string;
  expectedRevision: string;
  batchKey: string;
  correlationId: string | null;
}) {
  const { staff, supabase } = await portalAccessClient();
  const { data, error } = await supabase.schema("app").rpc("revoke_parent_portal_access", {
    p_season_id: input.seasonId,
    p_grant_ids: input.grantIds,
    p_reason: input.reason,
    p_expected_revision: input.expectedRevision,
    p_batch_key: input.batchKey,
    p_correlation_id: input.correlationId,
  });
  if (error) {
    logFailure("revoke", error.code || "mutation_failed");
    return { data: null, staff, error: error as PortalAccessRpcError };
  }
  const parsed = portalAccessCommitResponseSchema.safeParse(data);
  if (!parsed.success || parsed.data.operation !== "revoke") {
    logFailure("revoke", "response_invalid");
    throw new Error("PORTAL_ACCESS_COMMIT_RESPONSE_INVALID");
  }
  return { data: parsed.data, staff, error: null };
}
