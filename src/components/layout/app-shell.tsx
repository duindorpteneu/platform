"use client";

import { useEffect, useRef, useState } from "react";
import { usePathname, useRouter } from "next/navigation";
import {
  BarChart3,
  ClipboardList,
  Download,
  HelpCircle,
  History,
  KeyRound,
  LayoutDashboard,
  LogOut,
  Mail,
  Menu,
  Package,
  ScanLine,
  Settings,
  ShieldCheck,
  Shirt,
  Users,
  WalletCards,
  X,
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
  { label: "Uitgiftehistorie", href: "/backoffice/uitgifte", icon: History },
  { label: "E-mails", href: "/backoffice/emails", icon: Mail },
  { label: "Export", href: "/backoffice/export", icon: Download },
];

const roleLabels: Record<StaffRole, string> = { beheerder: "Beheerder", kledingcommissie: "Kledingcommissie", uitgifte: "Uitgifte" };

type StaffSummary = {
  displayName: string;
  role: StaffRole;
  activeSeason: { id: string; name: string } | null;
};

function navigationItemActive(pathname: string, href: string) {
  return href === "/backoffice" ? pathname === href : pathname.startsWith(href);
}

function NavigationPanel({
  staff,
  pathname,
  navigation,
  initials,
  onNavigate,
  onSignOut,
  closeButton,
}: {
  staff: StaffSummary;
  pathname: string;
  navigation: typeof primaryNavigation;
  initials: string;
  onNavigate?: () => void;
  onSignOut: () => void;
  closeButton?: React.ReactNode;
}) {
  return (
    <>
      <div className="flex h-[82px] items-center justify-between border-b border-white/10 px-6">
        <BrandMark />
        {closeButton}
      </div>
      <div className="flex flex-1 flex-col overflow-y-auto px-4 py-6">
        <p className="mb-3 px-3 text-[10px] font-bold uppercase tracking-[0.16em] text-blue-200/70">Werkruimte</p>
        <nav className="space-y-1" aria-label="Hoofdnavigatie">
          {navigation.map((item) => {
            const Icon = item.icon;
            const active = navigationItemActive(pathname, item.href);
            return (
              <Link key={item.href} href={item.href} onClick={onNavigate} aria-current={active ? "page" : undefined} className={cn("group flex min-h-11 items-center gap-3 rounded-lg px-3 py-2.5 text-[13px] font-medium text-blue-100 transition-colors hover:bg-white/10 hover:text-white", active && "bg-white/12 text-white shadow-sm") }>
                <Icon className={cn("size-[17px] text-blue-200/80", active && "text-white")} strokeWidth={1.8} />
                <span>{item.label}</span>
              </Link>
            );
          })}
        </nav>
        {staff.role !== "uitgifte" && <><div className="my-7 h-px bg-white/10" /><p className="mb-3 px-3 text-[10px] font-bold uppercase tracking-[0.16em] text-blue-200/70">Beheer</p><nav className="space-y-1" aria-label="Beheernavigatie">
          {staff.role === "beheerder" && <Link href="/backoffice/instellingen" onClick={onNavigate} aria-current={navigationItemActive(pathname, "/backoffice/instellingen") ? "page" : undefined} className={cn("flex min-h-11 items-center gap-3 rounded-lg px-3 py-2.5 text-[13px] font-medium text-blue-100 transition-colors hover:bg-white/10 hover:text-white", navigationItemActive(pathname, "/backoffice/instellingen") && "bg-white/12 text-white shadow-sm")}>
            <Settings className="size-[17px] text-blue-200/80" strokeWidth={1.8} />
            Instellingen
          </Link>}
          {staff.role === "beheerder" && <Link href="/backoffice/pakketten" onClick={onNavigate} aria-current={navigationItemActive(pathname, "/backoffice/pakketten") ? "page" : undefined} className={cn("flex min-h-11 items-center gap-3 rounded-lg px-3 py-2.5 text-[13px] font-medium text-blue-100 transition-colors hover:bg-white/10 hover:text-white", navigationItemActive(pathname, "/backoffice/pakketten") && "bg-white/12 text-white shadow-sm")}>
            <Package className="size-[17px] text-blue-200/80" strokeWidth={1.8} />
            Pakketten
          </Link>}
          {staff.role === "beheerder" && <Link href="/backoffice/portaaltoegang" onClick={onNavigate} aria-current={navigationItemActive(pathname, "/backoffice/portaaltoegang") ? "page" : undefined} className={cn("flex min-h-11 items-center gap-3 rounded-lg px-3 py-2.5 text-[13px] font-medium text-blue-100 transition-colors hover:bg-white/10 hover:text-white", navigationItemActive(pathname, "/backoffice/portaaltoegang") && "bg-white/12 text-white shadow-sm")}>
            <KeyRound className="size-[17px] text-blue-200/80" strokeWidth={1.8} />
            Portaaltoegang
          </Link>}
          <Link href="/backoffice/audit" onClick={onNavigate} aria-current={navigationItemActive(pathname, "/backoffice/audit") ? "page" : undefined} className={cn("flex min-h-11 items-center gap-3 rounded-lg px-3 py-2.5 text-[13px] font-medium text-blue-100 transition-colors hover:bg-white/10 hover:text-white", navigationItemActive(pathname, "/backoffice/audit") && "bg-white/12 text-white shadow-sm")}>
            <ShieldCheck className="size-[17px] text-blue-200/80" strokeWidth={1.8} />
            Auditlog
          </Link>
          <Link href="/backoffice/help" onClick={onNavigate} aria-current={navigationItemActive(pathname, "/backoffice/help") ? "page" : undefined} className={cn("flex min-h-11 items-center gap-3 rounded-lg px-3 py-2.5 text-[13px] font-medium text-blue-100 transition-colors hover:bg-white/10 hover:text-white", navigationItemActive(pathname, "/backoffice/help") && "bg-white/12 text-white shadow-sm")}>
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
          <button onClick={onSignOut} aria-label="Uitloggen" title="Uitloggen" className="flex size-11 items-center justify-center rounded-lg text-blue-200/70 hover:bg-white/10 hover:text-white"><LogOut className="size-4" /></button>
        </div>
      </div>
    </>
  );
}

export function AppShell({ children, staff }: { children: React.ReactNode; staff: StaffSummary }) {
  const pathname = usePathname();
  const router = useRouter();
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);
  const menuButtonRef = useRef<HTMLButtonElement>(null);
  const closeButtonRef = useRef<HTMLButtonElement>(null);
  const mobileNavigationRef = useRef<HTMLElement>(null);
  const isIssuance = pathname.startsWith("/uitgifte");
  const navigation = staff.role === "uitgifte"
    ? primaryNavigation.filter((item) => item.href === "/uitgifte")
    : staff.role === "kledingcommissie"
      ? primaryNavigation.filter((item) => item.href !== "/uitgifte")
      : primaryNavigation;
  const initials = staff.displayName.split(/\s+/).filter(Boolean).slice(0, 2).map((part) => part[0]?.toUpperCase()).join("") || "DS";

  useEffect(() => {
    if (!mobileMenuOpen) return;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    closeButtonRef.current?.focus();
    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") closeMobileMenu();
      if (event.key !== "Tab") return;
      const focusable = mobileNavigationRef.current?.querySelectorAll<HTMLElement>("a[href], button:not([disabled])");
      if (!focusable?.length) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };
    document.addEventListener("keydown", closeOnEscape);
    return () => {
      document.body.style.overflow = previousOverflow;
      document.removeEventListener("keydown", closeOnEscape);
    };
  }, [mobileMenuOpen]);

  function closeMobileMenu(restoreFocus = true) {
    setMobileMenuOpen(false);
    if (restoreFocus) requestAnimationFrame(() => menuButtonRef.current?.focus());
  }

  async function signOut() {
    setMobileMenuOpen(false);
    await fetch("/api/staff-auth/logout", {
      method: "POST",
      credentials: "same-origin",
      headers: { "X-Duindorp-CSRF": "same-origin" },
    }).catch(() => undefined);
    await getSupabaseBrowserClient()?.auth.signOut({ scope: "local" });
    router.replace("/staff/login");
    router.refresh();
  }

  return (
    <div className="min-h-screen bg-canvas text-ink">
      <aside className="fixed inset-y-0 left-0 z-30 hidden w-[248px] flex-col bg-brand-900 text-white lg:flex">
        <NavigationPanel staff={staff} pathname={pathname} navigation={navigation} initials={initials} onSignOut={() => void signOut()} />
      </aside>

      {mobileMenuOpen && <div className="fixed inset-0 z-50 lg:hidden">
        <button type="button" className="absolute inset-0 cursor-default bg-slate-950/55" aria-label="Mobiel menu sluiten" onClick={() => closeMobileMenu()} />
        <aside ref={mobileNavigationRef} id="mobile-navigation" role="dialog" aria-modal="true" aria-label="Mobiele navigatie" className="relative flex h-full w-[calc(100%-48px)] max-w-[320px] flex-col bg-brand-900 text-white shadow-2xl">
          <NavigationPanel
            staff={staff}
            pathname={pathname}
            navigation={navigation}
            initials={initials}
            onNavigate={() => closeMobileMenu(false)}
            onSignOut={() => void signOut()}
            closeButton={<button ref={closeButtonRef} type="button" aria-label="Menu sluiten" onClick={() => closeMobileMenu()} className="flex size-11 items-center justify-center rounded-lg text-blue-100 hover:bg-white/10 hover:text-white focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-white"><X className="size-5" /></button>}
          />
        </aside>
      </div>}

      <div className="lg:pl-[248px]">
        <header className="sticky top-0 z-20 flex h-[82px] items-center justify-between border-b border-line bg-white/95 px-4 backdrop-blur sm:px-5 md:px-8">
          <div className="flex items-center gap-2 lg:hidden">
            <button ref={menuButtonRef} type="button" aria-label="Menu openen" aria-controls="mobile-navigation" aria-expanded={mobileMenuOpen} onClick={() => setMobileMenuOpen(true)} className="flex size-11 items-center justify-center rounded-lg border border-line bg-white text-brand-900 shadow-sm hover:bg-slate-50 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-brand-700"><Menu className="size-5" /></button>
            <BrandMark compact />
            <span className="hidden text-sm font-bold text-brand-900 sm:inline">Tenueportaal</span>
          </div>
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
