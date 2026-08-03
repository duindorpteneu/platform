import { PackageSearch } from "lucide-react";
import Link from "next/link";
import { SupplierLoginForm } from "@/components/supplier/supplier-login-form";

export default function SupplierLoginPage() {
  return <main className="min-h-screen bg-brand-900 px-5 py-12"><div className="mx-auto flex min-h-[calc(100vh-96px)] max-w-[440px] items-center"><div className="w-full rounded-2xl bg-white p-7 shadow-2xl"><div className="flex size-12 items-center justify-center rounded-xl bg-brand-50 text-brand-700"><PackageSearch className="size-6" /></div><p className="mt-6 text-xs font-bold uppercase tracking-[0.14em] text-brand-500">Free-Kick Sport</p><h1 className="mt-2 text-2xl font-bold tracking-tight text-brand-900">Leveranciersplanning</h1><p className="mt-2 text-sm leading-6 text-slate-500">Gebruik de door Duindorp SV verstrekte toegangssleutel. De planning bevat uitsluitend geaggregeerde aantallen.</p><SupplierLoginForm /><p className="mt-5 text-center text-[11px] leading-5 text-slate-400">Sleutels worden door een beheerder uitgegeven en kunnen direct worden ingetrokken.</p><Link href="/" className="mt-6 block text-center text-xs font-semibold text-brand-700 hover:text-brand-900">Terug naar het tenueportaal</Link></div></div></main>;
}
