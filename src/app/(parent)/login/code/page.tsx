import { KeyRound } from "lucide-react";
import Link from "next/link";
import { cookies } from "next/headers";
import { ParentCodeForm } from "@/components/member/parent-code-form";
import {
  maskParentEmail,
  openParentChallengeContext,
} from "@/server/auth/parent";

export const dynamic = "force-dynamic";

export default async function ParentCodePage() {
  const cookieStore = await cookies();
  const context = openParentChallengeContext(
    cookieStore.get("duindorp_parent_challenge")?.value ?? "",
  );
  return <main className="min-h-screen bg-canvas px-5 py-12"><div className="mx-auto flex min-h-[calc(100vh-96px)] max-w-[520px] flex-col justify-center text-center"><div className="mx-auto flex size-14 items-center justify-center rounded-2xl bg-brand-700 text-white"><KeyRound className="size-6" /></div><p className="mt-6 text-xs font-bold uppercase tracking-[0.14em] text-brand-500">Verificatie</p><h1 className="mt-2 text-3xl font-bold tracking-tight text-brand-900">Controleer je e-mail</h1><p className="mx-auto mt-3 max-w-sm text-sm leading-6 text-slate-500">Vul de zescijferige code uit de nieuwste of opnieuw verstuurde e-mail in.</p><div className="mt-8">{context ? <ParentCodeForm maskedEmail={maskParentEmail(context.email)} expiresAt={context.expiresAt} cooldownUntil={context.cooldownUntil} /> : <div className="rounded-2xl border border-line bg-white p-6 text-sm text-slate-600 shadow-card">Vraag eerst een verificatiecode aan.</div>}</div><Link href="/login" className="mt-7 inline-block text-xs font-semibold text-brand-700 hover:text-brand-900">Ander e-mailadres gebruiken</Link></div></main>;
}
