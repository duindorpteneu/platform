import { PackageWorkspace } from "@/components/packages/package-workspace";
import { getPackageWorkspace } from "@/server/packages/workspace";

export const dynamic = "force-dynamic";

export default async function PackagesPage() {
  return <PackageWorkspace workspace={await getPackageWorkspace()} />;
}
