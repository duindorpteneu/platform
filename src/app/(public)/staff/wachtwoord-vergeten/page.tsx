import { KeyRound } from "lucide-react";
import { StaffPasswordRecoveryRequestForm } from "@/components/auth/staff-password-recovery-request-form";

export default function StaffPasswordRecoveryRequestPage() {
  return <main className="min-h-screen bg-brand-900 px-5 py-12"><div className="mx-auto flex min-h-[calc(100vh-96px)] max-w-[420px] items-center"><div className="w-full rounded-2xl bg-white p-7 shadow-2xl"><div className="flex size-12 items-center justify-center rounded-xl bg-brand-50 text-brand-700"><KeyRound className="size-6" /></div><p className="mt-6 text-xs font-bold uppercase tracking-[0.14em] text-brand-500">Medewerkersaccount</p><h1 className="mt-2 text-2xl font-bold tracking-tight text-brand-900">Wachtwoord herstellen</h1><p className="mt-2 text-sm leading-6 text-slate-500">Vraag een eenmalige, kort geldige link aan. Om misbruik te voorkomen is het antwoord voor ieder e-mailadres gelijk.</p><StaffPasswordRecoveryRequestForm /></div></div></main>;
}
