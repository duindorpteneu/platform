import { unstable_noStore as noStore } from "next/cache";
import {
  actionItemMutationResponseSchema,
  actionItemWorkspaceSchema,
  type ActionItemQuery,
} from "@/lib/action-item-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { operationalLogger } from "@/server/security/logger";
import { getSupabaseServerClient } from "@/server/supabase/server";

export type ActionItemRpcError = {
  code?: string;
  message?: string;
};

async function actionItemClient() {
  const staff = await requireStaffRole(["beheerder", "kledingcommissie"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) throw new Error("ACTION_ITEM_DATABASE_UNAVAILABLE");
  return { staff, supabase };
}

function logFailure(action: string, code: string) {
  operationalLogger.error(`action_item.${action}_failed`, {
    code: code.toLowerCase(),
    provider: "supabase",
    route: "/backoffice/actiepunten",
  });
}

export async function getActionItemWorkspace(input: ActionItemQuery) {
  noStore();
  const { staff, supabase } = await actionItemClient();
  const { data, error } = await supabase.schema("app").rpc(
    "get_action_item_workspace_v2",
    {
      p_season_id: input.seasonId,
      p_status: input.status,
      p_severity: input.severity,
      p_owner_user_id: input.ownerUserId,
      p_only_unassigned: input.onlyUnassigned,
      p_offset: input.offset,
      p_limit: input.limit,
    },
  );
  if (error) {
    logFailure("workspace_load", error.code || "query_failed");
    return { data: null, staff, error: error as ActionItemRpcError };
  }
  const parsed = actionItemWorkspaceSchema.safeParse(data);
  if (!parsed.success) {
    logFailure("workspace_load", "response_invalid");
    throw new Error("ACTION_ITEM_WORKSPACE_RESPONSE_INVALID");
  }
  return { data: parsed.data, staff, error: null };
}

type ActionItemMutation =
  | {
    operation: "assign";
    input: {
      actionItemId: string;
      expectedRevision: number;
      ownerUserId: string | null;
    };
  }
  | {
    operation: "start";
    input: {
      actionItemId: string;
      expectedRevision: number;
    };
  }
  | {
    operation: "resolve" | "dismiss";
    input: {
      actionItemId: string;
      expectedRevision: number;
      reason: string;
    };
  };

export async function mutateActionItem(
  mutation: ActionItemMutation,
  correlationId: string | null,
) {
  const { staff, supabase } = await actionItemClient();
  const call = mutation.operation === "assign"
    ? supabase.schema("app").rpc("assign_action_item", {
      p_action_item_id: mutation.input.actionItemId,
      p_expected_revision: mutation.input.expectedRevision,
      p_owner_user_id: mutation.input.ownerUserId,
      p_correlation_id: correlationId,
    })
    : mutation.operation === "start"
      ? supabase.schema("app").rpc("start_action_item", {
        p_action_item_id: mutation.input.actionItemId,
        p_expected_revision: mutation.input.expectedRevision,
        p_correlation_id: correlationId,
      })
      : supabase.schema("app").rpc(
        mutation.operation === "resolve"
          ? "resolve_action_item_v3"
          : "dismiss_action_item",
        {
          p_action_item_id: mutation.input.actionItemId,
          p_expected_revision: mutation.input.expectedRevision,
          p_reason: mutation.input.reason,
          p_correlation_id: correlationId,
        },
      );
  const { data, error } = await call;
  if (error) {
    logFailure(mutation.operation, error.code || "mutation_failed");
    return { data: null, staff, error: error as ActionItemRpcError };
  }
  const parsed = actionItemMutationResponseSchema.safeParse(data);
  if (!parsed.success) {
    logFailure(mutation.operation, "response_invalid");
    throw new Error("ACTION_ITEM_MUTATION_RESPONSE_INVALID");
  }
  return { data: parsed.data, staff, error: null };
}
