import { ShieldCheck } from "lucide-react";
import { StaffSetPasswordForm } from "@/components/auth/staff-set-password-form";

export default function StaffSetPasswordPage() {
  return <main className="min-h-screen bg-brand-900 px-5 py-12"><div className="mx-auto flex min-h-[calc(100vh-96px)] max-w-[440px] items-center"><div className="w-full rounded-2xl bg-white p-7 shadow-2xl"><div className="flex size-12 items-center justify-center rounded-xl bg-brand-50 text-brand-700"><ShieldCheck className="size-6" /></div><p className="mt-6 text-xs font-bold uppercase tracking-[0.14em] text-brand-500">Medewerkersuitnodiging</p><h1 className="mt-2 text-2xl font-bold tracking-tight text-brand-900">Stel je wachtwoord in</h1><p className="mt-2 text-sm leading-6 text-slate-500">Kies een uniek wachtwoord van minimaal 16 tekens. Daarna koppel je verplicht een authenticator-app.</p><StaffSetPasswordForm /></div></div></main>;
}
