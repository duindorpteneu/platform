import { ExportWorkspace } from "@/components/export/export-workspace";
import { getExportWorkspace } from "@/server/exports/workspace";

export const dynamic = "force-dynamic";

export default async function ExportPage() {
  return <ExportWorkspace workspace={await getExportWorkspace()} />;
}

