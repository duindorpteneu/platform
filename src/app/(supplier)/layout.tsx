import { redirect } from "next/navigation";
import { SupplierShell } from "@/components/supplier/supplier-shell";
import { getSupplierContext } from "@/server/auth/supplier";

export const dynamic = "force-dynamic";

export default async function SupplierLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const supplier = await getSupplierContext();
  if (!supplier) redirect("/leverancier/login");
  return <SupplierShell displayName={supplier.displayName}>{children}</SupplierShell>;
}
