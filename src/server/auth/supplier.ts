import { cookies } from "next/headers";
import type { SupplierContext } from "@/lib/supplier-contract";
import {
  fetchSupplierContext,
  hashSupplierSecret,
  SUPPLIER_SESSION_COOKIE,
} from "@/server/auth/supplier-context";

export async function getSupplierContext(): Promise<SupplierContext | null> {
  const token = (await cookies()).get(SUPPLIER_SESSION_COOKIE)?.value;
  return token ? fetchSupplierContext(token) : null;
}

export async function requireSupplierSessionBinding() {
  const token = (await cookies()).get(SUPPLIER_SESSION_COOKIE)?.value;
  const context = token ? await fetchSupplierContext(token) : null;
  if (!token || !context) throw new Error("SUPPLIER_AUTHORIZATION_REQUIRED");
  return {
    ...context,
    sessionTokenHash: await hashSupplierSecret(token),
  };
}
