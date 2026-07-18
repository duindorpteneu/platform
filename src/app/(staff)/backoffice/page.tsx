import { Dashboard } from "@/components/dashboard/dashboard";
import { getBackofficeDashboard } from "@/server/dashboard/overview";

export default async function BackofficePage() {
  const { overview, staff } = await getBackofficeDashboard();
  return <Dashboard overview={overview} displayName={staff.displayName} />;
}
