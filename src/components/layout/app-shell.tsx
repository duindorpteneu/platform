"use client";

import { usePathname } from "next/navigation";
import {
  BarChart3,
  ChevronDown,
  ClipboardList,
  Download,
  FileText,
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
import { cn } from "@/lib/utils";

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

export function AppShell({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const isIssuance = pathname.startsWith("/uitgifte");

  return (
    <div className="min-h-screen bg-canvas text-ink">
      <aside className="fixed inset-y-0 left-0 z-30 hidden w-[248px] flex-col bg-brand-900 text-white lg:flex">
        <div className="flex h-[82px] items-center border-b border-white/10 px-6">
          <BrandMark />
        </div>
        <div className="flex flex-1 flex-col overflow-y-auto px-4 py-6">
          <p className="mb-3 px-3 text-[10px] font-bold uppercase tracking-[0.16em] text-blue-200/70">Werkruimte</p>
          <nav className="space-y-1" aria-label="Hoofdnavigatie">
            {primaryNavigation.map((item) => {
              const Icon = item.icon;
              const active = item.href === "/backoffice" ? pathname === item.href : pathname.startsWith(item.href);
              return (
                <Link key={item.href} href={item.href} className={cn("group flex items-center gap-3 rounded-lg px-3 py-2.5 text-[13px] font-medium text-blue-100 transition-colors hover:bg-white/10 hover:text-white", active && "bg-white/12 text-white shadow-sm") }>
                  <Icon className={cn("size-[17px] text-blue-200/80", active && "text-white")} strokeWidth={1.8} />
                  <span>{item.label}</span>
                  {item.label === "Leden" && <span className="ml-auto rounded-full bg-white/10 px-2 py-0.5 text-[10px] text-blue-100">486</span>}
                </Link>
              );
            })}
          </nav>
          <div className="my-7 h-px bg-white/10" />
          <p className="mb-3 px-3 text-[10px] font-bold uppercase tracking-[0.16em] text-blue-200/70">Beheer</p>
          <nav className="space-y-1">
            <Link href="/backoffice/instellingen" className="flex items-center gap-3 rounded-lg px-3 py-2.5 text-[13px] font-medium text-blue-100 transition-colors hover:bg-white/10 hover:text-white">
              <Settings className="size-[17px] text-blue-200/80" strokeWidth={1.8} />
              Instellingen
            </Link>
            <Link href="/backoffice/help" className="flex items-center gap-3 rounded-lg px-3 py-2.5 text-[13px] font-medium text-blue-100 transition-colors hover:bg-white/10 hover:text-white">
              <HelpCircle className="size-[17px] text-blue-200/80" strokeWidth={1.8} />
              Helpcentrum
            </Link>
          </nav>
          <div className="mt-auto rounded-xl border border-white/10 bg-white/[0.06] p-4">
            <div className="mb-3 flex items-center justify-between">
              <span className="text-[11px] font-semibold text-blue-100">Seizoen 2025/26</span>
              <span className="size-2 rounded-full bg-emerald-400" />
            </div>
            <p className="text-[11px] leading-5 text-blue-200/70">Actief seizoen · laatste sync vandaag om 10:42</p>
          </div>
        </div>
        <div className="border-t border-white/10 p-4">
          <div className="flex items-center gap-3 rounded-lg px-2 py-2">
            <div className="flex size-8 items-center justify-center rounded-full bg-blue-500 text-[11px] font-bold text-white">DG</div>
            <div className="min-w-0 flex-1">
              <p className="truncate text-xs font-semibold">Danny Goldenbelt</p>
              <p className="truncate text-[10px] text-blue-200/70">Beheerder</p>
            </div>
            <LogOut className="size-4 text-blue-200/70" />
          </div>
        </div>
      </aside>

      <div className="lg:pl-[248px]">
        <header className="sticky top-0 z-20 flex h-[82px] items-center justify-between border-b border-line bg-white/95 px-5 backdrop-blur md:px-8">
          <div className="flex items-center gap-3 lg:hidden"><BrandMark compact /><span className="text-sm font-bold text-brand-900">Tenueportaal</span></div>
          <div className="hidden items-center gap-2 text-xs text-slate-500 lg:flex"><BarChart3 className="size-4 text-brand-500" /> Operationeel overzicht <span className="text-slate-300">/</span> {isIssuance ? "Uitgifte" : "Backoffice"}</div>
          <div className="ml-auto flex items-center gap-3">
            <button className="hidden items-center gap-2 rounded-lg border border-line bg-white px-3 py-2 text-xs font-semibold text-ink shadow-sm transition-colors hover:border-brand-500 md:flex">
              Seizoen 2025/26 <ChevronDown className="size-3.5 text-slate-400" />
            </button>
            <div className="hidden h-7 w-px bg-line md:block" />
            <button aria-label="Open meldingen" className="relative flex size-9 items-center justify-center rounded-lg text-slate-500 transition-colors hover:bg-canvas hover:text-brand-700"><FileText className="size-[17px]" strokeWidth={1.8} /><span className="absolute right-1.5 top-1.5 size-1.5 rounded-full bg-brand-500" /></button>
            <div className="flex items-center gap-2 border-l border-line pl-3"><div className="flex size-8 items-center justify-center rounded-full bg-brand-100 text-[11px] font-bold text-brand-700">DG</div><ChevronDown className="hidden size-3.5 text-slate-400 sm:block" /></div>
          </div>
        </header>
        <main className="min-h-[calc(100vh-82px)] px-5 py-7 md:px-8 md:py-9">{children}</main>
      </div>
    </div>
  );
}
