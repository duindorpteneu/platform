import { redirect } from "next/navigation";
import ParentLoginPage from "@/app/(public)/login/page";
import { getParentSession } from "@/server/auth/parent-session";

export default async function Home() {
  if (await getParentSession()) redirect("/mijn-tenue");
  return <ParentLoginPage />;
}
