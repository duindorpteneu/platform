import { CorrectionsWorkspace } from "@/components/fulfilment/corrections-workspace";
import { getFulfilmentCorrectionsWorkspace } from "@/server/fulfilment/corrections";
export const dynamic = "force-dynamic";
export default async function FulfilmentHistoryPage() {
  return <CorrectionsWorkspace workspace={await getFulfilmentCorrectionsWorkspace()} />;
}

