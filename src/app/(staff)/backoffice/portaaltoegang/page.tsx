import { PortalAccessWorkspace } from "@/components/portal-access/portal-access-workspace";
import { getPortalAccessWorkspace } from "@/server/portal-access/workspace";

export default async function PortalAccessPage() {
  const result = await getPortalAccessWorkspace({
    seasonId: null,
    search: null,
    offset: 0,
    limit: 50,
  });
  if (result.error || !result.data) throw new Error("PORTAL_ACCESS_WORKSPACE_QUERY_FAILED");
  return <PortalAccessWorkspace initial={result.data} />;
}
