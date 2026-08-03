import { SupplierPlanningWorkspace } from "@/components/supplier/supplier-planning-workspace";
import { getSupplierContext } from "@/server/auth/supplier";

export const dynamic = "force-dynamic";

export default async function SupplierPlanningPage() {
  const context = await getSupplierContext();
  if (!context) return null;
  return <SupplierPlanningWorkspace context={context} />;
}
