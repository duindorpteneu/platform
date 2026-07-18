import Link from "next/link";

export default function NotFound() {
  return <main className="flex min-h-screen items-center justify-center bg-canvas px-5 text-center"><div><p className="text-sm font-bold text-brand-500">404</p><h1 className="mt-2 text-2xl font-bold text-brand-900">Deze pagina bestaat niet</h1><p className="mt-2 text-sm text-slate-500">Ga terug naar het operationeel overzicht.</p><Link href="/backoffice" className="mt-6 inline-flex rounded-lg bg-brand-700 px-4 py-2.5 text-xs font-semibold text-white">Naar dashboard</Link></div></main>;
}
