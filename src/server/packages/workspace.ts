import { unstable_noStore as noStore } from "next/cache";
import {
  packageArchiveResponseSchema,
  packageCloneResponseSchema,
  packageDraftResponseSchema,
  packagePublishResponseSchema,
  packageWorkspaceSchema,
  type PackageDraftRequest,
  type PackageWorkspaceData,
} from "@/lib/package-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { operationalLogger } from "@/server/security/logger";
import { getSupabaseServerClient } from "@/server/supabase/server";

type PackageRpcError = {
  code?: string;
  message?: string;
};

function logWorkspaceFailure(code: string) {
  operationalLogger.error("packages.workspace_load_failed", {
    code: code.toLowerCase(),
    provider: "supabase",
    route: "/backoffice/pakketten",
  });
}

async function packageClient() {
  await requireStaffRole(["beheerder"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("PACKAGE_DATABASE_UNAVAILABLE");
  return supabase;
}

export async function getPackageWorkspace(): Promise<PackageWorkspaceData> {
  noStore();
  const supabase = await packageClient();
  const { data, error } = await supabase.schema("app").rpc("get_package_workspace");
  if (error) {
    logWorkspaceFailure(error.code || "query_failed");
    if (error.code === "42501") throw new Error("STAFF_AUTHORIZATION_REQUIRED");
    if (error.code === "PGRST106" || error.code === "PGRST202") throw new Error("PACKAGE_SCHEMA_CONTRACT_STALE");
    throw new Error("PACKAGE_WORKSPACE_QUERY_FAILED");
  }
  const parsed = packageWorkspaceSchema.safeParse(data);
  if (!parsed.success) {
    logWorkspaceFailure("response_invalid");
    throw new Error("PACKAGE_WORKSPACE_RESPONSE_INVALID");
  }
  return parsed.data;
}

export async function savePackageDraft(input: PackageDraftRequest, correlationId: string | null) {
  const supabase = await packageClient();
  const { data, error } = await supabase.schema("app").rpc("upsert_package_draft", {
    p_template_id: input.templateId,
    p_revision_id: input.revisionId,
    p_season_id: input.seasonId,
    p_template_key: input.key,
    p_name: input.name,
    p_description: input.description,
    p_price_cents: input.priceCents,
    p_items: input.items,
    p_expected_hash: input.expectedHash,
    p_correlation_id: correlationId,
  });
  if (error) return { data: null, error: error as PackageRpcError };
  const parsed = packageDraftResponseSchema.safeParse(data);
  if (!parsed.success) throw new Error("PACKAGE_MUTATION_RESPONSE_INVALID");
  return { data: parsed.data, error: null };
}

export async function clonePackageRevision(
  templateId: string,
  sourceRevisionId: string,
  expectedHash: string,
  correlationId: string | null,
) {
  const supabase = await packageClient();
  const { data, error } = await supabase.schema("app").rpc("clone_package_revision", {
    p_template_id: templateId,
    p_source_revision_id: sourceRevisionId,
    p_expected_hash: expectedHash,
    p_correlation_id: correlationId,
  });
  if (error) return { data: null, error: error as PackageRpcError };
  const parsed = packageCloneResponseSchema.safeParse(data);
  if (!parsed.success) throw new Error("PACKAGE_MUTATION_RESPONSE_INVALID");
  return { data: parsed.data, error: null };
}

export async function publishPackageRevision(
  revisionId: string,
  makeDefault: boolean,
  expectedHash: string,
  correlationId: string | null,
) {
  const supabase = await packageClient();
  const { data, error } = await supabase.schema("app").rpc("publish_package_revision", {
    p_revision_id: revisionId,
    p_make_default: makeDefault,
    p_expected_hash: expectedHash,
    p_correlation_id: correlationId,
  });
  if (error) return { data: null, error: error as PackageRpcError };
  const parsed = packagePublishResponseSchema.safeParse(data);
  if (!parsed.success) throw new Error("PACKAGE_MUTATION_RESPONSE_INVALID");
  return { data: parsed.data, error: null };
}

export async function archivePackageRevision(
  revisionId: string,
  reason: string,
  expectedHash: string,
  correlationId: string | null,
) {
  const supabase = await packageClient();
  const { data, error } = await supabase.schema("app").rpc("archive_package_revision", {
    p_revision_id: revisionId,
    p_reason: reason,
    p_expected_hash: expectedHash,
    p_correlation_id: correlationId,
  });
  if (error) return { data: null, error: error as PackageRpcError };
  const parsed = packageArchiveResponseSchema.safeParse(data);
  if (!parsed.success) throw new Error("PACKAGE_MUTATION_RESPONSE_INVALID");
  return { data: parsed.data, error: null };
}
