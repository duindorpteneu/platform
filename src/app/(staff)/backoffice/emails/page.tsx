import { EmailWorkspace } from "@/components/email/email-workspace";
import {
  getMailV2CutoverSnapshot,
  getMailV2Workspace,
} from "@/server/email/mail-v2-workspace";
import { getMailV2CampaignWorkspace } from "@/server/email/mail-v2-campaigns";
import { getMailReminderWorkspace } from "@/server/email/mail-v2-reminders";
import { getEmailWorkspace } from "@/server/email/workspace";

export const dynamic = "force-dynamic";

export default async function EmailsPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const rawTab = (await searchParams).tab;
  const initialTab = rawTab === "bulk" || rawTab === "branding" || rawTab === "templates"
    ? rawTab
    : undefined;
  const { workspace, staff } = await getEmailWorkspace();
  const canManageTemplates = staff.role === "beheerder";
  const campaignWorkspacePromise = getMailV2CampaignWorkspace();
  const [
    mailV2Workspace,
    mailV2Cutover,
    campaignWorkspace,
    reminderWorkspace,
  ] = canManageTemplates
    ? await Promise.all([
      getMailV2Workspace(),
      getMailV2CutoverSnapshot(),
      campaignWorkspacePromise,
      getMailReminderWorkspace(),
    ])
    : [undefined, undefined, await campaignWorkspacePromise, undefined];
  return (
    <EmailWorkspace
      workspace={workspace}
      mailV2Workspace={mailV2Workspace}
      mailV2Cutover={mailV2Cutover}
      campaignWorkspace={campaignWorkspace}
      reminderWorkspace={reminderWorkspace}
      canManageTemplates={canManageTemplates}
      emailEnabled={process.env.EMAIL_ENABLED === "true"}
      initialTab={initialTab}
    />
  );
}
