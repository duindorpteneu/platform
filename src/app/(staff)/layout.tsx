import { AppShell } from "@/components/layout/app-shell";
import { redirect } from "next/navigation";
import { getStaffContext } from "@/server/auth/staff";

export const dynamic = "force-dynamic";

export default async function StaffLayout({ children }: { children: React.ReactNode }) {
  const staff = await getStaffContext();
  if (!staff) redirect("/staff/login");
  return <AppShell staff={{ displayName: staff.displayName, role: staff.role, activeSeason: staff.activeSeason }}>{children}</AppShell>;
}
