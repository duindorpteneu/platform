import { ActionItemsWorkspace } from "@/components/action-items/action-items-workspace";
import { getActionItemWorkspace } from "@/server/action-items/workspace";

export default async function ActionItemsPage() {
  const result = await getActionItemWorkspace({
    seasonId: null,
    status: null,
    severity: null,
    ownerUserId: null,
    onlyUnassigned: false,
    offset: 0,
    limit: 50,
  });
  if (result.error || !result.data) {
    throw new Error("ACTION_ITEM_WORKSPACE_QUERY_FAILED");
  }
  return <ActionItemsWorkspace initial={result.data} />;
}
