import { KeyRound } from "lucide-react";
import Link from "next/link";
import { Suspense } from "react";
import { ParentCodeForm } from "@/components/member/parent-code-form";

export default function ParentCodePage() {
  return <main className="min-h-screen bg-canvas px-5 py-12"><div className="mx-auto flex min-h-[calc(100vh-96px)] max-w-[520px] flex-col justify-center text-center"><div className="mx-auto flex size-14 items-center justify-center rounded-2xl bg-brand-700 text-white"><KeyRound className="size-6" /></div><p className="mt-6 text-xs font-bold uppercase tracking-[0.14em] text-brand-500">Verificatie</p><h1 className="mt-2 text-3xl font-bold tracking-tight text-brand-900">Voer je code in</h1><p className="mx-auto mt-3 max-w-sm text-sm leading-6 text-slate-500">Controleer je e-mail en vul de code hieronder in.</p><div className="mt-8"><Suspense fallback={<div className="h-56 rounded-2xl border border-line bg-white shadow-card" />}><ParentCodeForm /></Suspense></div><Link href="/login" className="mt-7 inline-block text-xs font-semibold text-brand-700 hover:text-brand-900">Ander e-mailadres gebruiken</Link></div></main>;
}
