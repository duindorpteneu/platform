"use client";

import { LogOut, PackageSearch } from "lucide-react";
import { useRouter } from "next/navigation";
import { BrandMark } from "@/components/layout/brand-mark";

export function SupplierShell({
  children,
  displayName,
}: {
  children: React.ReactNode;
  displayName: string;
}) {
  const router = useRouter();
  async function logout() {
    await fetch("/api/supplier-auth/logout", {
      method: "POST",
      credentials: "same-origin",
      headers: { "X-Duindorp-CSRF": "same-origin" },
    }).catch(() => undefined);
    router.replace("/leverancier/login");
    router.refresh();
  }
  return <div className="min-h-screen bg-canvas text-ink">
    <header className="border-b border-white/10 bg-brand-900 text-white">
      <div className="mx-auto flex h-[76px] max-w-[1440px] items-center gap-4 px-5 md:px-8">
        <BrandMark />
        <div className="ml-auto flex items-center gap-3">
          <span className="hidden items-center gap-2 text-xs text-blue-100 sm:flex"><PackageSearch className="size-4" />{displayName}</span>
          <button type="button" onClick={() => void logout()} className="inline-flex min-h-11 items-center gap-2 rounded-lg px-3 text-xs font-bold text-blue-100 hover:bg-white/10 hover:text-white">
            <LogOut className="size-4" />Uitloggen
          </button>
        </div>
      </div>
    </header>
    <main className="mx-auto max-w-[1440px] px-5 py-8 md:px-8 md:py-10">{children}</main>
  </div>;
}
