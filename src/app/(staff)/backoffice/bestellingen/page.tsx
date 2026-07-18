import { OrdersWorkspace } from "@/components/orders/orders-workspace";
import { getCatalogOrderWorkspace } from "@/server/catalog/workspace";

export const dynamic = "force-dynamic";

export default async function OrdersPage() {
  const { workspace } = await getCatalogOrderWorkspace();
  return <OrdersWorkspace workspace={workspace} />;
}
