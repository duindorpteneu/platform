import { EmailWorkspace } from "@/components/email/email-workspace";
import { getEmailWorkspace } from "@/server/email/workspace";

export const dynamic = "force-dynamic";

export default async function EmailsPage() {
  const { workspace } = await getEmailWorkspace();
  return <EmailWorkspace workspace={workspace} emailEnabled={process.env.EMAIL_ENABLED === "true"} />;
}
