import { SettingsWorkspace } from "@/components/settings/settings-workspace";
import { getSettingsWorkspace } from "@/server/settings/workspace";

export const dynamic = "force-dynamic";

export default async function SettingsPage() {
  const workspace = await getSettingsWorkspace();
  return <SettingsWorkspace workspace={workspace} />;
}

