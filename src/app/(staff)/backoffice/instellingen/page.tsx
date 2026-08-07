import { SettingsWorkspace } from "@/components/settings/settings-workspace";
import { getReleaseControlWorkspace } from "@/server/settings/release-controls";
import { getSettingsWorkspace } from "@/server/settings/workspace";

export const dynamic = "force-dynamic";

export default async function SettingsPage() {
  const [workspace, releaseControls] = await Promise.all([
    getSettingsWorkspace(),
    getReleaseControlWorkspace(),
  ]);
  return (
    <SettingsWorkspace
      workspace={workspace}
      releaseControls={releaseControls}
    />
  );
}
