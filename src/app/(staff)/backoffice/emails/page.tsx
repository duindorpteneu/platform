import { EmailWorkspace } from "@/components/email/email-workspace";
import {
  getMailV2CutoverSnapshot,
  getMailV2Workspace,
} from "@/server/email/mail-v2-workspace";
import { getMailV2CampaignWorkspace } from "@/server/email/mail-v2-campaigns";
import { getEmailWorkspace } from "@/server/email/workspace";

export const dynamic = "force-dynamic";

export default async function EmailsPage() {
  const { workspace, staff } = await getEmailWorkspace();
  const canManageTemplates = staff.role === "beheerder";
  const campaignWorkspacePromise = getMailV2CampaignWorkspace();
  const [mailV2Workspace, mailV2Cutover, campaignWorkspace] = canManageTemplates
    ? await Promise.all([
      getMailV2Workspace(),
      getMailV2CutoverSnapshot(),
      campaignWorkspacePromise,
    ])
    : [undefined, undefined, await campaignWorkspacePromise];
  return (
    <EmailWorkspace
      workspace={workspace}
      mailV2Workspace={mailV2Workspace}
      mailV2Cutover={mailV2Cutover}
      campaignWorkspace={campaignWorkspace}
      canManageTemplates={canManageTemplates}
      emailEnabled={process.env.EMAIL_ENABLED === "true"}
    />
  );
}
