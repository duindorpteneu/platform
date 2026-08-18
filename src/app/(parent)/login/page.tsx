import { LockKeyhole } from "lucide-react";
import Link from "next/link";
import { ParentLoginForm } from "@/components/member/parent-login-form";

export default function ParentLoginPage() {
  return <main className="min-h-screen bg-canvas px-5 py-12"><div className="mx-auto flex min-h-[calc(100vh-96px)] max-w-[520px] flex-col justify-center text-center"><div className="mx-auto flex size-14 items-center justify-center rounded-2xl bg-brand-700 text-white"><LockKeyhole className="size-6" /></div><p className="mt-6 text-xs font-bold uppercase tracking-[0.14em] text-brand-500">Mijn Duindorp SV tenue</p><h1 className="mt-2 text-3xl font-bold tracking-tight text-brand-900">Bekijk jouw tenue</h1><p className="mx-auto mt-3 max-w-sm text-sm leading-6 text-slate-500">Log in met je e-mailadres. We sturen je een eenmalige zescijferige code.</p><div className="mt-8"><ParentLoginForm /></div><Link href="/staff/login" className="mt-7 inline-block text-xs font-semibold text-brand-700 hover:text-brand-900">Medewerkerlogin</Link></div></main>;
}
