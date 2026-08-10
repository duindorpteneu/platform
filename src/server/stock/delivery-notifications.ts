import { unstable_noStore as noStore } from "next/cache";
import {
  deliveryNotificationConfirmResponseSchema,
  deliveryNotificationProposalSchema,
  type DeliveryNotificationConfirmRequest,
} from "@/lib/delivery-notification-contract";
import { requireStaffRole } from "@/server/auth/staff";
import { operationalLogger } from "@/server/security/logger";
import { getSupabaseServerClient } from "@/server/supabase/server";

type RpcError = { code?: string; message?: string };

async function notificationClient() {
  await requireStaffRole(["beheerder", "kledingcommissie"]);
  const supabase = await getSupabaseServerClient();
  if (!supabase) {
    throw new Error("DELIVERY_NOTIFICATION_DATABASE_UNAVAILABLE");
  }
  return supabase;
}

function logFailure(action: string, code: string) {
  operationalLogger.error(`inventory.delivery_notification.${action}_failed`, {
    code: code.toLowerCase(),
    provider: "supabase",
    route: "/backoffice/leveringen",
  });
}

export async function getDeliveryNotificationProposal(
  deliveryDraftId: string,
) {
  noStore();
  const supabase = await notificationClient();
  const { data, error } = await supabase.schema("app").rpc(
    "get_inventory_delivery_notification_proposal_v1",
    { p_delivery_draft_id: deliveryDraftId },
  );
  if (error) {
    logFailure("preview", error.code || "query_failed");
    return { data: null, error: error as RpcError };
  }
  const parsed = deliveryNotificationProposalSchema.safeParse(data);
  if (!parsed.success) {
    logFailure("preview", "response_invalid");
    throw new Error("DELIVERY_NOTIFICATION_RESPONSE_INVALID");
  }
  return { data: parsed.data, error: null };
}

export async function confirmDeliveryNotificationProposal(
  input: DeliveryNotificationConfirmRequest,
  correlationId: string | null,
) {
  const supabase = await notificationClient();
  const { data, error } = await supabase.schema("app").rpc(
    "confirm_inventory_delivery_notification_proposal_v1",
    {
      p_proposal_id: input.proposalId,
      p_expected_revision: input.expectedRevision,
      p_excluded_item_ids: input.excludedItemIds,
      p_request_id: input.requestId,
      p_correlation_id: correlationId,
    },
  );
  if (error) {
    logFailure("confirm", error.code || "mutation_failed");
    return { data: null, error: error as RpcError };
  }
  const parsed = deliveryNotificationConfirmResponseSchema.safeParse(data);
  if (!parsed.success) {
    logFailure("confirm", "response_invalid");
    throw new Error("DELIVERY_NOTIFICATION_CONFIRM_RESPONSE_INVALID");
  }
  return { data: parsed.data, error: null };
}
