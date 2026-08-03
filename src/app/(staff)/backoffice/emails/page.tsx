import { EmailWorkspace } from "@/components/email/email-workspace";
import { getMailV2Workspace } from "@/server/email/mail-v2-workspace";
import { getEmailWorkspace } from "@/server/email/workspace";

export const dynamic = "force-dynamic";

export default async function EmailsPage() {
  const { workspace, staff } = await getEmailWorkspace();
  const canManageTemplates = staff.role === "beheerder";
  const mailV2Workspace = canManageTemplates ? await getMailV2Workspace() : undefined;
  return (
    <EmailWorkspace
      workspace={workspace}
      mailV2Workspace={mailV2Workspace}
      canManageTemplates={canManageTemplates}
      emailEnabled={process.env.EMAIL_ENABLED === "true"}
    />
  );
}
