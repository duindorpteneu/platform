import { OrdersWorkspace } from "@/components/orders/orders-workspace";
import { getCatalogOrderWorkspace } from "@/server/catalog/workspace";

export const dynamic = "force-dynamic";

export default async function OrdersPage() {
  const { workspace, staff } = await getCatalogOrderWorkspace();
  return (
    <OrdersWorkspace
      workspace={workspace}
      canManagePackages={staff.role === "beheerder"}
    />
  );
}
