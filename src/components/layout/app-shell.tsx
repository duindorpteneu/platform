"use client";

import { usePathname, useRouter } from "next/navigation";
import {
  BarChart3,
  ClipboardList,
  Download,
  HelpCircle,
  LayoutDashboard,
  LogOut,
  Mail,
  Package,
  ScanLine,
  Settings,
  Shirt,
  Users,
  WalletCards,
} from "lucide-react";
import Link from "next/link";
import { BrandMark } from "@/components/layout/brand-mark";
import { getSupabaseBrowserClient } from "@/lib/supabase/client";
import { cn } from "@/lib/utils";
import type { StaffRole } from "@/server/auth/staff";

const primaryNavigation = [
  { label: "Dashboard", href: "/backoffice", icon: LayoutDashboard },
  { label: "Leden", href: "/backoffice/leden", icon: Users },
  { label: "Artikelen", href: "/backoffice/artikelen", icon: Shirt },
  { label: "Bestellingen", href: "/backoffice/bestellingen", icon: ClipboardList },
  { label: "Betalingen", href: "/backoffice/betalingen", icon: WalletCards },
  { label: "Leveringen", href: "/backoffice/leveringen", icon: Package },
  { label: "Uitgifte", href: "/uitgifte", icon: ScanLine },
  { label: "E-mails", href: "/backoffice/emails", icon: Mail },
  { label: "Export", href: "/backoffice/export", icon: Download },
];

const roleLabels: Record<StaffRole, string> = { beheerder: "Beheerder", kledingcommissie: "Kledingcommissie", uitgifte: "Uitgifte" };

export function AppShell({ children, staff }: { children: React.ReactNode; staff: { displayName: string; role: StaffRole; activeSeason: { id: string; name: string } | null } }) {
  const pathname = usePathname();
  const router = useRouter();
  const isIssuance = pathname.startsWith("/uitgifte");
  const navigation = staff.role === "uitgifte" ? primaryNavigation.filter((item) => item.href === "/uitgifte") : primaryNavigation;
  const initials = staff.displayName.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]?.toUpperCase()).join("") || "DS";

  async function signOut() {
    await getSupabaseBrowserClient()?.auth.signOut({ scope: "local" });
    router.replace("/staff/login");
    router.refresh();
  }

  return (
    <div className="min-h-screen bg-canvas text-ink">
      <aside className="fixed inset-y-0 left-0 z-30 hidden w-[248px] flex-col bg-brand-900 text-white lg:flex">
        <div className="flex h-[82px] items-center border-b border-white/10 px-6">
          <BrandMark />
        </div>
        <div className="flex flex-1 flex-col overflow-y-auto px-4 py-6">
          <p className="mb-3 px-3 text-[10px] font-bold uppercase tracking-[0.16em] text-blue-200/70">Werkruimte</p>
          <nav className="space-y-1" aria-label="Hoofdnavigatie">
            {navigation.map((item) => {
              const Icon = item.icon;
              const active = item.href === "/backoffice" ? pathname === item.href : pathname.startsWith(item.href);
              return (
                <Link key={item.href} href={item.href} className={cn("group flex items-center gap-3 rounded-lg px-3 py-2.5 text-[13px] font-medium text-blue-100 transition-colors hover:bg-white/10 hover:text-white", active && "bg-white/12 text-white shadow-sm") }>
                  <Icon className={cn("size-[17px] text-blue-200/80", active && "text-white")} strokeWidth={1.8} />
                  <span>{item.label}</span>
                </Link>
              );
            })}
          </nav>
          {staff.role !== "uitgifte" && <><div className="my-7 h-px bg-white/10" /><p className="mb-3 px-3 text-[10px] font-bold uppercase tracking-[0.16em] text-blue-200/70">Beheer</p><nav className="space-y-1">
            {staff.role === "beheerder" && <Link href="/backoffice/instellingen" className="flex items-center gap-3 rounded-lg px-3 py-2.5 text-[13px] font-medium text-blue-100 transition-colors hover:bg-white/10 hover:text-white">
              <Settings className="size-[17px] text-blue-200/80" strokeWidth={1.8} />
              Instellingen
            </Link>}
            <Link href="/backoffice/help" className="flex items-center gap-3 rounded-lg px-3 py-2.5 text-[13px] font-medium text-blue-100 transition-colors hover:bg-white/10 hover:text-white">
              <HelpCircle className="size-[17px] text-blue-200/80" strokeWidth={1.8} />
              Helpcentrum
            </Link>
          </nav></>}
          <div className="mt-auto rounded-xl border border-white/10 bg-white/[0.06] p-4">
            <div className="mb-3 flex items-center justify-between">
              <span className="text-[11px] font-semibold text-blue-100">{staff.activeSeason?.name ?? "Geen actief seizoen"}</span>
              <span className={cn("size-2 rounded-full", staff.activeSeason ? "bg-emerald-400" : "bg-slate-400")} />
            </div>
            <p className="text-[11px] leading-5 text-blue-200/70">{staff.activeSeason ? "Actief tenue-seizoen" : "Activeer een seizoen via Instellingen"}</p>
          </div>
        </div>
        <div className="border-t border-white/10 p-4">
          <div className="flex items-center gap-3 rounded-lg px-2 py-2">
            <div className="flex size-8 items-center justify-center rounded-full bg-blue-500 text-[11px] font-bold text-white">{initials}</div>
            <div className="min-w-0 flex-1">
              <p className="truncate text-xs font-semibold">{staff.displayName}</p>
              <p className="truncate text-[10px] text-blue-200/70">{roleLabels[staff.role]}</p>
            </div>
            <button onClick={() => void signOut()} aria-label="Uitloggen" title="Uitloggen" className="flex size-8 items-center justify-center rounded-lg text-blue-200/70 hover:bg-white/10 hover:text-white"><LogOut className="size-4" /></button>
          </div>
        </div>
      </aside>

      <div className="lg:pl-[248px]">
        <header className="sticky top-0 z-20 flex h-[82px] items-center justify-between border-b border-line bg-white/95 px-5 backdrop-blur md:px-8">
          <div className="flex items-center gap-3 lg:hidden"><BrandMark compact /><span className="text-sm font-bold text-brand-900">Tenueportaal</span></div>
          <div className="hidden items-center gap-2 text-xs text-slate-500 lg:flex"><BarChart3 className="size-4 text-brand-500" /> Operationeel overzicht <span className="text-slate-300">/</span> {isIssuance ? "Uitgifte" : "Backoffice"}</div>
          <div className="ml-auto flex items-center gap-3">
            <div className="hidden rounded-lg border border-line bg-white px-3 py-2 text-xs font-semibold text-ink shadow-sm md:block">{staff.activeSeason?.name ?? "Geen actief seizoen"}</div>
            <div className="hidden h-7 w-px bg-line md:block" />
            <div className="flex items-center gap-2 border-l border-line pl-3"><div className="flex size-8 items-center justify-center rounded-full bg-brand-100 text-[11px] font-bold text-brand-700">{initials}</div><span className="hidden text-xs font-semibold text-ink xl:inline">{staff.displayName}</span></div>
          </div>
        </header>
        <main className="min-h-[calc(100vh-82px)] px-5 py-7 md:px-8 md:py-9">{children}</main>
      </div>
    </div>
  );
}
