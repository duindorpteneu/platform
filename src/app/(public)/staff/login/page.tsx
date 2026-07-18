import { LockKeyhole } from "lucide-react";
import Link from "next/link";
import { StaffLoginForm } from "@/components/auth/staff-login-form";

export default function LoginPage() {
  return <main className="min-h-screen bg-brand-900 px-5 py-12"><div className="mx-auto flex min-h-[calc(100vh-96px)] max-w-[420px] items-center"><div className="w-full rounded-2xl bg-white p-7 shadow-2xl"><div className="flex size-12 items-center justify-center rounded-xl bg-brand-50 text-brand-700"><LockKeyhole className="size-6" /></div><p className="mt-6 text-xs font-bold uppercase tracking-[0.14em] text-brand-500">Backoffice</p><h1 className="mt-2 text-2xl font-bold tracking-tight text-brand-900">Veilig inloggen</h1><p className="mt-2 text-sm leading-6 text-slate-500">Log in met je medewerkersaccount. Daarna bevestig je toegang met verplichte MFA.</p><StaffLoginForm /><p className="mt-5 text-center text-[11px] text-slate-400">Accounts worden uitsluitend door de beheerder uitgegeven.</p><Link href="/mijn-tenue" className="mt-6 block text-center text-xs font-semibold text-brand-700 hover:text-brand-900">Naar ledenportaal</Link></div></div></main>;
}
