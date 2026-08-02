import { DynamicImportWorkspace } from "@/components/imports/dynamic-import-workspace";
import { getDynamicImportWorkspace } from "@/server/imports/workspace";

export const dynamic = "force-dynamic";

export default async function DynamicImportPage() {
  return <DynamicImportWorkspace workspace={await getDynamicImportWorkspace()} />;
}
