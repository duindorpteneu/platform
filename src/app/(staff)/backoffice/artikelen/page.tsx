import { CatalogWorkspace } from "@/components/catalog/catalog-workspace";
import { getCatalogOrderWorkspace } from "@/server/catalog/workspace";

export const dynamic = "force-dynamic";

export default async function ArticlesPage() {
  const { workspace } = await getCatalogOrderWorkspace();
  return <CatalogWorkspace workspace={workspace} />;
}
